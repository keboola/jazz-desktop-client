using System.Text;
using JazzCaptureCore;
using JazzCaptureCore.Consent;
using static JazzCaptureCoreTests.ConsentTestSupport;

namespace JazzCaptureCoreTests;

public sealed class ConsentTextTests
{
    [Fact]
    public void HashMatchesWhenSha256OfTheUtf8BodyIsEqual()
    {
        Assert.True(Text("0.3", "# Souhlas\n\nŽluťoučký kůň.").HashMatches());
    }

    [Fact]
    public void HashMatchIgnoresTheCaseOfTheServedHex()
    {
        ServedText text = Text("0.3");

        Assert.True((text with { Sha256 = text.Sha256.ToUpperInvariant() }).HashMatches());
    }

    [Fact]
    public void AChangedBodyFailsTheHashCheck()
    {
        ServedText text = Text("0.3", "You agree.");

        Assert.False((text with { Body = "You agree. " }).HashMatches());
    }

    [Fact]
    public void KnownVector()
    {
        var text = new ServedText("1", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "abc");

        Assert.True(text.HashMatches());
    }

    [Fact]
    public void ParsesHeadingsParagraphsBulletsBoldAndItalic()
    {
        const string body = "# Title\n\nFirst line\nsecond line.\n\n## Part\n\n- one **bold**\n- two *slanted*\n\nEnd.";

        IReadOnlyList<ConsentBlock> blocks = ConsentMarkdown.Parse(body);

        Assert.Equal(
            new[] { ConsentBlockKind.Heading, ConsentBlockKind.Paragraph, ConsentBlockKind.Heading, ConsentBlockKind.ListItem, ConsentBlockKind.ListItem, ConsentBlockKind.Paragraph },
            blocks.Select(block => block.Kind).ToArray());
        Assert.Equal(1, blocks[0].Level);
        Assert.Equal(2, blocks[2].Level);
        Assert.Equal("First line second line.", blocks[1].PlainText);
        Assert.Equal(
            new[] { new ConsentSpan("one ", false, false), new ConsentSpan("bold", true, false) },
            blocks[3].Spans.ToArray());
        Assert.Equal(new ConsentSpan("slanted", false, true), blocks[4].Spans[1]);
    }

    [Fact]
    public void AnUnclosedStarStaysPlainText()
    {
        ConsentBlock block = Assert.Single(ConsentMarkdown.Parse("2 * 3 and a * star"));

        Assert.Equal("2 * 3 and a * star", block.PlainText);
        Assert.All(block.Spans, span => Assert.False(span.Bold || span.Italic));
    }

    [Fact]
    public void LinksAndOtherMarkupStayPlainText()
    {
        ConsentBlock block = Assert.Single(ConsentMarkdown.Parse("See [the page](https://example.com) <b>now</b>."));

        Assert.Equal("See [the page](https://example.com) <b>now</b>.", block.PlainText);
    }

    [Fact]
    public void HandlesWindowsLineEndings()
    {
        Assert.Equal(2, ConsentMarkdown.Parse("# A\r\n\r\nB").Count);
    }

    [Fact]
    public void ParsesAServedBodyShapedLikeTheRealTexts()
    {
        const string body = "# Jazz is about to record your work\n\nAcme uses Jazz.\n\n## Changing your mind\n\nYou can withdraw your consent at any time from the Jazz icon: choose *Withdraw consent*. Recording stops from that moment.\n\n{if x}";

        IReadOnlyList<ConsentBlock> blocks = ConsentMarkdown.Parse(body);

        Assert.Equal(ConsentBlockKind.Heading, blocks[0].Kind);
        Assert.Contains(blocks[3].Spans, span => span.Italic && span.Text == "Withdraw consent");
    }

    [Fact]
    public void EntraPersonIsReadFromTheTokenClaims()
    {
        string payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(
                "{\"tid\":\"11111111-1111-1111-1111-111111111111\",\"oid\":\"22222222-2222-2222-2222-222222222222\"}"))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');

        Assert.True(EntraPerson.TryRead("e30." + payload + ".sig", out string tenant, out string person));

        Assert.Equal("11111111-1111-1111-1111-111111111111", tenant);
        Assert.Equal("22222222-2222-2222-2222-222222222222", person);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-a-token")]
    [InlineData("a.%%%.c")]
    [InlineData("a.e30.c")]
    public void AnUnreadableTokenNamesNoPerson(string token)
    {
        Assert.False(EntraPerson.TryRead(token, out _, out _));
    }

    [Fact]
    public void TheWindowsKeyIsTheSameForAnyCaseOfTheName()
    {
        ConsentIdentity upper = ConsentIdentity.ForWindows(@"ACME\JNovak", "S-1-5-21-1-2-3-1001");
        ConsentIdentity lower = ConsentIdentity.ForWindows(@"acme\jnovak", "S-1-5-21-1-2-3-1001");

        Assert.Equal(lower, upper);
        Assert.Equal(@"acme\jnovak", upper.ConsentKey);
        Assert.Equal(@"acme\jnovak", upper.QualifiedUser);
        Assert.Equal("S-1-5-21-1-2-3-1001", upper.WindowsSid);
    }

    [Fact]
    public void ARenamedWindowsAccountKeepsTheStoreKey()
    {
        ConsentIdentity before = ConsentIdentity.ForWindows(@"acme\jnovak", "S-1-5-21-1-2-3-1001");
        ConsentIdentity after = ConsentIdentity.ForWindows(@"acme\jnovakova", "S-1-5-21-1-2-3-1001");

        Assert.Equal(before.StoreKey, after.StoreKey);
        Assert.NotEqual(before.ConsentKey, after.ConsentKey);
    }

    [Fact]
    public void TheEntraKeyIsTenantAndObjectAndSendsNoSid()
    {
        ConsentIdentity identity = ConsentIdentity.ForEntra(
            "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222", @"AzureAD\JNovak");

        Assert.Equal(ConsentRoute.Entra, identity.Route);
        Assert.Equal("11111111-1111-1111-1111-111111111111/22222222-2222-2222-2222-222222222222", identity.ConsentKey);
        Assert.Null(identity.WindowsSid);
        Assert.Equal(@"azuread\jnovak", identity.QualifiedUser);
        Assert.NotEqual(
            identity.StoreKey,
            ConsentIdentity.ForEntra("99999999-9999-9999-9999-999999999999", "22222222-2222-2222-2222-222222222222", "x").StoreKey);
    }

    [Fact]
    public void ParsesTheServedPolicyOfPullRequest699()
    {
        ServedText text = Text("0.3");
        ServedText notice = Text("1", "# Notice");
        string json = PolicyJson(
            new
            {
                policy = "company_wide",
                key = "entra_tid_oid",
                text = new { language = "en", variant = "continuous", version = text.Version, sha256 = text.Sha256, body = text.Body },
                notice = ServedObject(notice),
                reask = new { onTextVersion = "agreed_only" },
            });

        Assert.True(DevicePolicy.TryParse(json, out DevicePolicy? policy));

        Assert.Equal("active", policy!.Status);
        Assert.Equal(RecordingMode.Continuous, policy.Mode);
        Assert.Equal(120, policy.RefreshSeconds);
        Assert.Equal("0.20.0", policy.MinClientVersion);
        Assert.Equal(ConsentPolicyKind.CompanyWide, policy.Consent!.Policy);
        Assert.Equal(text, policy.Consent.Text);
        Assert.Equal(notice, policy.Consent.Notice);
        Assert.Null(policy.Consent.ModeNotice);
    }

    [Fact]
    public void ClampsTheRefreshIntervalAndRejectsForeignDocuments()
    {
        Assert.True(DevicePolicy.TryParse(
            "{\"kind\":\"jazz-windows-client-policy\",\"schema\":1,\"status\":\"active\",\"consentRefreshSeconds\":1}",
            out DevicePolicy? policy));
        Assert.Equal(DevicePolicy.MinimumRefreshSeconds, policy!.RefreshSeconds);
        Assert.Null(policy.Consent);

        string[] rejected =
        {
            "not-json",
            "[]",
            "{\"kind\":\"other\",\"schema\":1,\"status\":\"active\"}",
            "{\"kind\":\"jazz-windows-client-policy\",\"schema\":2,\"status\":\"active\"}",
            "{\"kind\":\"jazz-windows-client-policy\",\"schema\":1}",
        };
        foreach (string json in rejected)
            Assert.False(DevicePolicy.TryParse(json, out _));
    }

    [Fact]
    public void AnUnknownConsentPolicyOrIncompleteTextIsIgnored()
    {
        Assert.True(DevicePolicy.TryParse(PolicyJson(new { policy = "everyone", text = new { version = "1" } }), out DevicePolicy? unknown));
        Assert.Null(unknown!.Consent);

        Assert.True(DevicePolicy.TryParse(PolicyJson(new { policy = "per_person", text = new { version = "1" } }), out DevicePolicy? partial));
        Assert.Null(partial!.Consent!.Text);
    }

    [Theory]
    [InlineData("0.26.9", "0.27.0", true)]
    [InlineData("0.27.0", "0.27.0", false)]
    [InlineData("0.27.1", "0.27.0", false)]
    [InlineData("1.0.0", "0.99.0", false)]
    [InlineData("0.27", "0.27.0", false)]
    [InlineData("0.27.0", null, false)]
    [InlineData("0.27.0", "garbage", false)]
    public void ComparesClientVersions(string current, string? minimum, bool expectedBelow)
    {
        Assert.Equal(expectedBelow, ClientVersion.IsBelow(current, minimum));
    }

    [Fact]
    public void TheLedgerRoundTripsAndABrokenFileGrantsNothing()
    {
        ConsentIdentity identity = ConsentIdentity.ForWindows(@"acme\jnovak", "S-1-5-21-1-2-3-1001");
        ConsentLedger ledger = ConsentLedger.Empty() with
        {
            LastIdentity = identity,
            People = new Dictionary<string, PersonConsentState>
            {
                [identity.StoreKey] = new PersonConsentState(
                    new ConsentAnswer(ConsentDecision.Agreed, "0.3", "abc", "session", DateTimeOffset.UnixEpoch, true), "1", "1/session"),
            },
        };

        ConsentLedger read = ConsentLedger.Parse(ledger.ToJson());

        Assert.Equal(identity, read.LastIdentity);
        Assert.Equal(ledger.People[identity.StoreKey], read.Person(identity.StoreKey));
        Assert.Equal(PersonConsentState.Empty, ConsentLedger.Parse("{broken").Person(identity.StoreKey));
        Assert.Equal(PersonConsentState.Empty, ConsentLedger.Parse(null).Person(identity.StoreKey));
        Assert.Equal(PersonConsentState.Empty, ConsentLedger.Parse("{\"schema\":9,\"people\":{}}").Person(identity.StoreKey));
    }
}
