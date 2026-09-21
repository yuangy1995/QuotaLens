using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using QuotaLens.Core;
using QuotaLens.Infrastructure;

int passed = 0;
void Check(bool value, string name) { if (!value) throw new Exception("FAILED: " + name); passed++; Console.WriteLine("PASS " + name); }
async Task Reject(Func<Task> action, string name) { bool failed = false; try { await action(); } catch { failed = true; } Check(failed, name); }
byte[] ReadShared(string path) {
    using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
    using var content = new MemoryStream(); stream.CopyTo(content); return content.ToArray();
}
string root = Path.Combine(Path.GetTempPath(), "QuotaLens isolated tests " + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
try {
    string vaultRoot = Path.Combine(root, "vault");
    using (var vault = new CredentialVault(vaultRoot)) {
        var credential = new Credential(Provider.Codex, "synthetic-access-for-tests", "synthetic-refresh-for-tests");
        await vault.SaveAsync("account_a", credential); await vault.SaveAsync("account_b", credential with { AccessToken = "another-synthetic-access" });
        Check((await vault.LoadAsync<Credential>("account_a"))?.AccessToken == credential.AccessToken, "DPAPI/GCM round trip");
        string pathA = Path.Combine(vaultRoot, "account_a.qcred"), pathB = Path.Combine(vaultRoot, "account_b.qcred");
        byte[] originalA = File.ReadAllBytes(pathA), originalB = File.ReadAllBytes(pathB);
        Check(!Encoding.UTF8.GetString(originalA).Contains(credential.AccessToken), "ciphertext does not contain the token");
        File.WriteAllBytes(pathA, originalB);
        await Reject(async () => { _ = await vault.LoadAsync<Credential>("account_a"); }, "record substitution rejected by AAD");
        await Reject(() => vault.SaveAsync("account_a", credential), "tampered record is not overwritten");
        File.WriteAllBytes(pathA, originalA);
        string master = Path.Combine(vaultRoot, "master.key.dpapi"); byte[] originalMaster = File.ReadAllBytes(master); File.Delete(master);
        await Reject(() => vault.SaveAsync("account_c", credential), "missing master does not regenerate over old ciphertext");
        Check(File.ReadAllBytes(pathA).SequenceEqual(originalA) && !File.Exists(master), "missing-key failure preserves files");
        File.WriteAllBytes(master, ProtectedData.Protect(RandomNumberGenerator.GetBytes(32), Encoding.ASCII.GetBytes("QuotaLens.Windows.MasterKey.v1"), DataProtectionScope.CurrentUser));
        await Reject(() => vault.SaveAsync("account_a", credential), "a mismatched valid DPAPI key cannot overwrite ciphertext");
        Check(File.ReadAllBytes(pathA).SequenceEqual(originalA), "wrong-key save preserves old ciphertext"); File.WriteAllBytes(master, originalMaster);
        var rules = new FileInfo(pathA).GetAccessControl().GetAccessRules(true, true, typeof(SecurityIdentifier));
        Check(!rules.Cast<FileSystemAccessRule>().Any(rule => rule.IdentityReference.Value == "S-1-1-0" && rule.AccessControlType == AccessControlType.Allow), "credential ACL has no Everyone grant");
        await vault.RemoveAsync("account_b"); Check(await vault.LoadAsync<Credential>("account_b") is null, "explicit credential removal");
    }
    using var database = new LocalDatabase(Path.Combine(root, "app")); await database.InitializeAsync();
    var indexer = new UsageIndexer(database); string sessions = Path.Combine(root, "sessions"); Directory.CreateDirectory(sessions);
    string file = Path.Combine(sessions, "rollout-test.jsonl");
    string meta = """{"timestamp":"2026-09-01T00:00:00Z","type":"session_meta","payload":{"id":"test-session","cwd":"C:/synthetic-project"}}""";
    string context = """{"timestamp":"2026-09-01T00:00:01Z","type":"turn_context","payload":{"model":"synthetic-model","effort":"high"}}""";
    string first = """{"timestamp":"2026-09-01T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":50}}}}""";
    string second = """{"timestamp":"2026-09-01T00:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":40,"output_tokens":80}}}}""";
    string body = """{"timestamp":"2026-09-01T00:00:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SYNTHETIC-CONVERSATION-DO-NOT-INDEX"}]}}""";
    await File.WriteAllTextAsync(file, string.Join('\n', meta, context, first, body) + "\n", new UTF8Encoding(false));
    await indexer.ScanAsync(Provider.Codex, [sessions]);
    Task<UsageReport> Report() => database.UsageAsync(Provider.Codex, DateTimeOffset.Parse("2026-01-01T00:00:00Z"), DateTimeOffset.Parse("2027-01-01T00:00:00Z"), []);
    var report = await Report(); Check(report.Tokens == 150 && report.Cached == 20, "initial cumulative Codex counters");
    int middle = second.Length / 2;
    await File.AppendAllTextAsync(file, second[..middle], new UTF8Encoding(false));
    await indexer.ScanAsync(Provider.Codex, [sessions]); Check((await Report()).Tokens == 150, "unfinished final line is not indexed");
    await File.AppendAllTextAsync(file, second[middle..] + "\n", new UTF8Encoding(false));
    await indexer.ScanAsync(Provider.Codex, [sessions]); Check((await Report()).Tokens == 280, "completed append adds only the cumulative delta");
    await indexer.ScanAsync(Provider.Codex, [sessions], true); Check((await Report()).Tokens == 280, "full rescan is idempotent");
    string copy = Path.Combine(sessions, "copy.jsonl"); File.Copy(file, copy);
    await indexer.ScanAsync(Provider.Codex, [sessions]); Check((await Report()).Tokens == 280, "duplicate source files do not double count logical usage");
    string originalText = await File.ReadAllTextAsync(file); await File.WriteAllTextAsync(file, "{broken-json}\n");
    var failed = await indexer.ScanAsync(Provider.Codex, [sessions]);
    Check(failed.Failed == 1 && (await Report()).Tokens == 280, "malformed source replacement retains previous facts transactionally");
    await File.WriteAllTextAsync(file, originalText, new UTF8Encoding(false)); await indexer.ScanAsync(Provider.Codex, [sessions], true);
    var source = (await database.SourcesAsync(Provider.Codex)).Single(x => x.Path == file);
    var transcript = await indexer.TranscriptAsync(source);
    Check(transcript.Lines.Any(x => x.Text.Contains("SYNTHETIC-CONVERSATION")), "conversation replay reads source on demand");
    var search = await indexer.SearchAsync("DO-NOT-INDEX"); Check(search.Hits.Count > 0, "full-text search reads original source");
    string diagnostics = await database.DiagnosticsAsync();
    Check(!diagnostics.Contains(file) && !diagnostics.Contains("SYNTHETIC-CONVERSATION"), "diagnostics omit paths and conversation content");
    foreach (string storage in Directory.EnumerateFiles(database.Root, "quotalens.sqlite*"))
        Check(!Encoding.UTF8.GetString(ReadShared(storage)).Contains("SYNTHETIC-CONVERSATION-DO-NOT-INDEX"), "analytical storage excludes conversation bodies: " + Path.GetExtension(storage));
    Check(report.ApiValue is null && report.UnpricedEvents > 0, "unknown models remain unpriced");
    await Reject(() => database.PutMetadataAsync("bad", new Credential(Provider.Codex, "synthetic")), "plaintext credential metadata rejected");
    var account = new Account(Account.KeyFor(Provider.Codex, "synthetic-account"), Provider.Codex, "synthetic-account", "test@example.invalid", "test", DateTimeOffset.UtcNow);
    await database.SaveAccountAsync(account);
    var quota = new QuotaSnapshot(account.Key, Provider.Codex, DateTimeOffset.UtcNow, "test", [new("codex:primary_window", "Codex", 25, 300, DateTimeOffset.UtcNow.AddHours(5))]);
    await database.SaveQuotaAsync(quota); await database.SaveQuotaAsync(quota);
    Check((await database.QuotaHistoryAsync(account.Key)).Count == 1, "snapshot observations are idempotent");
    var redemption = await database.PrepareRedemptionAsync(account.Key, "synthetic-credit");
    Check((await database.PrepareRedemptionAsync(account.Key, "synthetic-credit")).IdempotencyKey == redemption.IdempotencyKey, "reset retries keep the durable idempotency key");
    await database.RemoveAccountAsync(account.Key);
    Check(await database.LatestQuotaAsync(account.Key) is not null && (await Report()).Tokens == 280, "removing an account preserves quota and local history");
    Check(await database.IsDiscoveryExcludedAsync(account.Key), "removed accounts are excluded from automatic discovery");
    await database.SaveAccountAsync(account, true); Check(!await database.IsDiscoveryExcludedAsync(account.Key), "explicit import clears discovery exclusion");
    await database.ForgetSourceAsync(source.Id); Check((await Report()).Tokens == 280, "deleting one duplicate source preserves shared facts");
    File.SetLastWriteTimeUtc(copy, DateTime.UtcNow.AddMinutes(-5)); await indexer.ScanFileAsync(Provider.Codex, copy, true);
    var recovery = new RecoveryService(database, indexer); var copySource = (await database.SourcesAsync(Provider.Codex)).Single(x => x.Path == copy);
    var entry = await recovery.MoveAsync(copySource, CancellationToken.None);
    Check(!File.Exists(copy) && File.Exists(entry.StoredPath) && (await Report()).Tokens == 0, "recoverable move removes only that source's derived facts");
    await recovery.RestoreAsync(entry.Id, CancellationToken.None);
    Check(File.Exists(copy) && !File.Exists(entry.StoredPath) && (await Report()).Tokens == 280, "restore returns the original file and rebuilds its index");
    using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
    await Reject(() => indexer.ScanAsync(Provider.Codex, [sessions], true, cancelled.Token), "scan cancellation is observed");
    Check(AntigravityActivityReader.Parse("").Count == 0, "empty aggregate activity is valid");
    await Reject(() => Task.Run(() => AntigravityActivityReader.Parse("not-base64")), "malformed activity is rejected without a zero fallback");
    string truncated = Convert.ToBase64String(new byte[] { 10, 255 });
    await Reject(() => Task.Run(() => AntigravityActivityReader.Parse(truncated)), "truncated protobuf is rejected");
    Console.WriteLine($"{passed} Windows infrastructure checks passed using isolated synthetic data only.");
} finally {
    Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools(); if (Directory.Exists(root)) Directory.Delete(root, true);
}
