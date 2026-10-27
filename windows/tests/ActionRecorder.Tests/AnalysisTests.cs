using ActionRecorder.Core;

namespace ActionRecorder.Tests;

public static class AnalysisTests
{
    private static Recording Make(params MacroAction[] actions)
    {
        var r = new Recording("t");
        r.Actions.AddRange(actions);
        return r;
    }

    private static List<MacroFinding> Analyze(Recording r, PlaybackDefaults? playback = null, bool foreground = false, ScreenSize? screen = null) =>
        MacroAnalyzer.Analyze(r, playback ?? new PlaybackDefaults(), foreground, screen);

    [Test]
    public static void EmptyRecordingHasNoFindings()
    {
        Check.Equal(0, Analyze(Make()).Count);
    }

    [Test]
    public static void SecretLookingTextIsFlagged()
    {
        Check.True(MacroAnalyzer.LooksLikeSecret("Hunter2!xyz"));
        Check.True(MacroAnalyzer.LooksLikeSecret("aB3$aB3$"));
        Check.False(MacroAnalyzer.LooksLikeSecret("hello world"));
        Check.False(MacroAnalyzer.LooksLikeSecret("short1A!"[..5]));
        Check.False(MacroAnalyzer.LooksLikeSecret("https://example.com/Path123"));
        Check.False(MacroAnalyzer.LooksLikeSecret("justlowercaseletters"));
        Check.False(MacroAnalyzer.LooksLikeSecret(new string('a', 70) + "1A!"));
        var findings = Analyze(Make(Act.Text("Hunter2!xyz")));
        Check.True(findings.Any(f => f.Id == "secret-text" && f.Severity == FindingSeverity.Warning));
    }

    [Test]
    public static void ScreenChangeIsFlaggedOnlyForClicks()
    {
        var r = Make(Act.Click(10, 10));
        r.RecordedScreen = new ScreenSize(1920, 1080);
        Check.True(Analyze(r, screen: new ScreenSize(2560, 1440)).Any(f => f.Id == "screen-changed"));
        Check.False(Analyze(r, screen: new ScreenSize(1920, 1080)).Any(f => f.Id == "screen-changed"));
        var keyboardOnly = Make(Act.Text("hi"));
        keyboardOnly.RecordedScreen = new ScreenSize(1920, 1080);
        Check.False(Analyze(keyboardOnly, screen: new ScreenSize(2560, 1440)).Any(f => f.Id == "screen-changed"));
    }

    [Test]
    public static void RapidMessagesWarningAndFix()
    {
        var r = Make(Act.Text("hi"), Act.Key(KeyCodes.Return));
        var findings = Analyze(r, new PlaybackDefaults(1, 10, 1));
        var finding = findings.First(f => f.Id == "rapid-messages");
        Check.Equal(FixKind.SetLoopDelay, finding.Fix!.Kind);
        Check.Equal(MacroAnalyzer.SuggestedLoopDelay, finding.Fix.Seconds);
        Check.False(Analyze(r, new PlaybackDefaults(1, 10, 5)).Any(f => f.Id == "rapid-messages"));
        Check.False(Analyze(r, new PlaybackDefaults(1, 2, 0)).Any(f => f.Id == "rapid-messages"));
        Check.True(Analyze(r, new PlaybackDefaults(1, 0, 0)).Any(f => f.Id == "rapid-messages"), "0 repeats means forever");
    }

    [Test]
    public static void ForegroundWarning()
    {
        var r = Make(Act.Click(1, 1));
        r.TargetApp = new TargetApp("discord.exe", "Discord");
        Check.True(Analyze(r).Any(f => f.Id == "foreground-off" && f.Fix!.Kind == FixKind.EnableForegroundCheck));
        Check.False(Analyze(r, foreground: true).Any(f => f.Id == "foreground-off"));
        r.TargetApp = null;
        Check.True(Analyze(r).Any(f => f.Id == "no-target-app"));
    }

    [Test]
    public static void ManyMovesAndLongPauses()
    {
        var actions = new List<MacroAction>();
        for (var i = 0; i < 30; i++) actions.Add(Act.Move(i, i, delay: 0.01));
        actions.Add(Act.Click(1, 1, delay: 12));
        var r = Make(actions.ToArray());
        var findings = Analyze(r);
        Check.True(findings.Any(f => f.Id == "many-moves" && f.Fix!.Kind == FixKind.RemoveMouseMoves));
        Check.True(findings.Any(f => f.Id == "long-pauses" && f.Fix!.Kind == FixKind.CapLongPauses));
        Check.True(findings.Any(f => f.Id == "click-based"));
    }

    [Test]
    public static void WarningsComeFirst()
    {
        var r = Make(Act.Click(1, 1), Act.Text("Hunter2!xyz"));
        var findings = Analyze(r);
        var firstInfo = findings.FindIndex(f => f.Severity == FindingSeverity.Info);
        var lastWarning = findings.FindLastIndex(f => f.Severity == FindingSeverity.Warning);
        Check.True(lastWarning < firstInfo);
    }

    // ------------------------------------------------------------- optimizer

    [Test]
    public static void OptimizerRemovesMousePathsButKeepsTheLastBeforeNonClicks()
    {
        var m1 = Act.Move(1, 1); var m2 = Act.Move(2, 2); var m3 = Act.Move(3, 3); var m4 = Act.Move(4, 4);
        var click = Act.Click(5, 5);
        var m5 = Act.Move(6, 6); var m6 = Act.Move(7, 7); var m7 = Act.Move(8, 8);
        var r = Make(m1, m2, m3, m4, click, m5, m6, m7);
        var edits = MacroOptimizer.Plan(r);
        var delete = (EditOperation.Delete)edits.Single(e => e.Id == "rule-remove-moves").Operation;
        // Before the click: all four. Trailing run (no click after): keep the last position.
        Check.SequenceEqual(new[] { m1.Id, m2.Id, m3.Id, m4.Id, m5.Id, m6.Id }, delete.Ids);
        Check.Equal(1, r.ApplyEdits(edits.Where(e => e.Id == "rule-remove-moves")));
        Check.Equal(2, r.Actions.Count); // the click and the final resting position
    }

    [Test]
    public static void ShortMovementRunsAreLeftAlone()
    {
        var r = Make(Act.Move(1, 1), Act.Move(2, 2), Act.Click(3, 3));
        Check.Equal(0, MacroOptimizer.Plan(r).Count(e => e.Id == "rule-remove-moves"));
    }

    [Test]
    public static void OptimizerMergesTextAndSettlesTyping()
    {
        var a = Act.Text("hel", delay: 0.2);
        var b = Act.Text("lo", delay: 0.5);
        var r = Make(Act.Click(1, 1), a, b);
        var edits = MacroOptimizer.Plan(r);
        Check.True(edits.Any(e => e.Id == "rule-merge-text"));
        Check.True(edits.Any(e => e.Id == "rule-settle-text"));
        Check.Equal(2, r.ApplyEdits(edits));
        Check.Equal(2, r.Actions.Count);
        Check.Equal("hello", r.Actions[1].Text);
        Check.True(r.Actions[1].Delay >= MacroOptimizer.SettleDelay);
    }

    [Test]
    public static void OptimizerCapsLongPauses()
    {
        var r = Make(Act.Click(1, 1, delay: 40), Act.Wait(30), Act.Click(2, 2, delay: 1));
        var edits = MacroOptimizer.Plan(r);
        Check.True(edits.Any(e => e.Id == "rule-cap-pauses"));
        r.ApplyEdits(edits);
        Check.Equal(MacroAnalyzer.PauseCap, r.Actions[0].Delay);
        Check.Equal(MacroAnalyzer.PauseCap, r.Actions[1].Duration!.Value);
        Check.Equal(1.0, r.Actions[2].Delay);
        Check.Equal(0, MacroOptimizer.Plan(r).Count(e => e.Id == "rule-cap-pauses"));
    }

    [Test]
    public static void StaleEditsAreSkipped()
    {
        var a = Act.Click(1, 1);
        var r = Make(a);
        var edit = new MacroEdit("x", EditSource.Rule, new EditOperation.Delete(new[] { Guid.NewGuid() }), "t", "r");
        Check.Equal(0, r.ApplyEdits(new[] { edit }));
        Check.Equal(1, r.Actions.Count);
        var bad = new MacroEdit("y", EditSource.Rule, new EditOperation.CapPauses(1, 5), "t", "r");
        Check.Equal(0, r.ApplyEdits(new[] { bad }));
        var nan = new MacroEdit("z", EditSource.Rule, new EditOperation.SetMinimumDelay(new[] { a.Id }, double.NaN), "t", "r");
        Check.Equal(0, r.ApplyEdits(new[] { nan }));
    }

    // ------------------------------------------------------------- AI edit parser

    [Test]
    public static void AiEditsAreParsedAndLimited()
    {
        var r = Make(Act.Key(KeyCodes.K, KeyModifiers.Control), Act.Text("general", delay: 0.1), Act.Key(KeyCodes.Return), Act.Move(1, 1), Act.Text("hi"));
        var reply = "Sure! Here you go:\n1. PAUSE step 2 1.5 | typing right after the shortcut\n- **DELETE 3** | duplicate\nDELETE 4 | mouse move (must be ignored)\nDELETE 99 | missing\nREWRITE 1 | nope\nPAUSE #5 99s | too long";
        var edits = AIEditParser.Parse(reply, r);
        Check.Equal(3, edits.Count);
        var pause = (EditOperation.SetMinimumDelay)edits[0].Operation;
        Check.Equal(1.5, pause.Seconds);
        Check.True(edits.All(e => e.Source == EditSource.Ai));
        var capped = (EditOperation.SetMinimumDelay)edits[2].Operation;
        Check.Equal(AIEditParser.MaxPause, capped.Seconds);
        Check.Equal("typing right after the shortcut", edits[0].Reason);
    }

    [Test]
    public static void AiDeleteCountIsCapped()
    {
        var r = Make(Act.Text("a"), Act.Text("b"), Act.Text("c"), Act.Text("d"));
        var reply = "DELETE 1\nDELETE 2\nDELETE 3\nDELETE 4";
        var edits = AIEditParser.Parse(reply, r);
        Check.Equal(2, edits.Count); // at most half of the editable steps
    }

    [Test]
    public static void AiNoneAndGarbageProduceNothing()
    {
        var r = Make(Act.Text("a"));
        Check.Equal(0, AIEditParser.Parse("NONE", r).Count);
        Check.Equal(0, AIEditParser.Parse("", r).Count);
        Check.Equal(0, AIEditParser.Parse("DELETE\nPAUSE 1\nPAUSE 1 abc\nPAUSE 1 -3\nDELETE x", r).Count);
        Check.Equal(0, AIEditParser.Parse("DELETE 1", Make()).Count);
    }

    [Test]
    public static void AiDuplicateLinesAreCollapsed()
    {
        var r = Make(Act.Text("a"), Act.Text("b"), Act.Text("c"));
        Check.Equal(1, AIEditParser.Parse("PAUSE 2 1\nPAUSE 2 2", r).Count);
    }

    // ------------------------------------------------------------- AI drafter

    [Test]
    public static void DraftParsesKeysTextAndWaits()
    {
        var draft = AIMacroDrafter.Parse("KEY ctrl+k\nTYPE general\nKEY enter\nWAIT 1.5\nTYPE \"hello there\"\nKEY shift+enter");
        Check.Equal(6, draft.Actions.Count);
        Check.Equal(KeyCodes.K, draft.Actions[0].KeyCode!.Value);
        Check.Equal(KeyModifiers.Control, draft.Actions[0].Modifiers!.Value);
        Check.Equal("general", draft.Actions[1].Text);
        Check.Equal(AIMacroDrafter.KeyCodesByName["enter"], draft.Actions[2].KeyCode!.Value);
        Check.Equal(1.5, draft.Actions[3].Duration!.Value);
        Check.Equal("hello there", draft.Actions[4].Text);
        Check.Equal(KeyModifiers.Shift, draft.Actions[5].Modifiers!.Value);
        Check.Equal(0, draft.SkippedLines);
        Check.False(draft.Unsupported);
    }

    [Test]
    public static void DraftSetsHumanDelays()
    {
        var draft = AIMacroDrafter.Parse("KEY ctrl+k\nTYPE general\nKEY enter");
        Check.Equal(0.0, draft.Actions[0].Delay);
        Check.Equal(0.5, draft.Actions[1].Delay); // after a shortcut
        Check.Equal(0.4, draft.Actions[2].Delay); // Enter after typing
    }

    [Test]
    public static void DraftMapsMacTermsToWindows()
    {
        var draft = AIMacroDrafter.Parse("KEY cmd+k");
        Check.Equal(KeyModifiers.Control, draft.Actions[0].Modifiers!.Value);
        var win = AIMacroDrafter.Parse("KEY win+d");
        Check.Equal(KeyModifiers.Command, win.Actions[0].Modifiers!.Value);
    }

    [Test]
    public static void DraftIgnoresProseAndCountsBadLines()
    {
        var draft = AIMacroDrafter.Parse("Here is the macro:\n```\nKEY ctrl+nonsense\nKEY hyper+k\nTYPE\nWAIT soon\nclick the button\nKEY tab\n```");
        Check.Equal(1, draft.Actions.Count);
        Check.Equal(4, draft.SkippedLines);
    }

    [Test]
    public static void DraftWaitsAreClamped()
    {
        var draft = AIMacroDrafter.Parse("WAIT 0\nWAIT 9999");
        Check.Equal(AIMacroDrafter.MinWait, draft.Actions[0].Duration!.Value);
        Check.Equal(AIMacroDrafter.MaxWait, draft.Actions[1].Duration!.Value);
    }

    [Test]
    public static void DraftUnsupportedAndLimits()
    {
        Check.True(AIMacroDrafter.Parse("UNSUPPORTED").Unsupported);
        Check.False(AIMacroDrafter.Parse("UNSUPPORTED\nKEY tab").Unsupported);
        var many = string.Join("\n", Enumerable.Repeat("KEY tab", 100));
        Check.Equal(AIMacroDrafter.MaxActions, AIMacroDrafter.Parse(many).Actions.Count);
        var longText = AIMacroDrafter.Parse("TYPE " + new string('x', 600));
        Check.Equal(0, longText.Actions.Count);
    }

    [Test]
    public static void DraftOutputPassesValidation()
    {
        var draft = AIMacroDrafter.Parse("KEY ctrl+k\nTYPE hi\nKEY enter\nWAIT 2");
        var r = new Recording("d");
        r.Actions.AddRange(draft.Actions);
        Check.Equal(0, RecordingValidator.Errors(RecordingValidator.Validate(r)).Count);
    }

    [Test]
    public static void ModelNamesAreCleaned()
    {
        Check.Equal("Open Discord channel", AiPrompts.CleanName("\"Open Discord channel.\"\nExtra explanation"));
        Check.Equal("Send hello", AiPrompts.CleanName("  “Send hello”  "));
    }

    [Test]
    public static void SummariesCollapseMouseMovesAndKeepStepNumbers()
    {
        var r = Make(Act.Move(1, 1), Act.Move(2, 2), Act.Click(5, 5, delay: 2), Act.Text("hi"));
        r.Name = "Demo";
        r.TargetApp = new TargetApp("discord.exe", "Discord");
        var text = MacroSummary.Text(r);
        Check.True(text.Contains("Move the mouse (2 steps)"));
        Check.True(text.Contains("Recorded in: Discord"));
        Check.True(text.Contains("after a 2.00 s pause"));
        var numbered = MacroSummary.NumberedText(r);
        Check.True(numbered.Contains("#3 Left click at (5, 5)"));
        Check.True(numbered.Contains("#4 Type “hi”"));
        Check.True(numbered.Contains("mouse movements: 2"));
    }

    [Test]
    public static void LongSummariesAreTrimmedWithCorrectNumbers()
    {
        var r = new Recording("big");
        for (var i = 0; i < 200; i++) r.Actions.Add(Act.Text("t" + i));
        var numbered = MacroSummary.NumberedText(r, 30);
        Check.True(numbered.Contains("#1 "));
        Check.True(numbered.Contains("#200 "));
        Check.True(numbered.Contains("lines omitted"));
        Check.True(numbered.Split('\n').Length < 45);
    }
}
