using System.Reflection;

namespace ActionRecorder.Tests;

[AttributeUsage(AttributeTargets.Method)]
public sealed class TestAttribute : Attribute
{
}

public sealed class AssertionFailed : Exception
{
    public AssertionFailed(string message) : base(message)
    {
    }
}

/// <summary>A tiny test framework so the tests need no NuGet packages (and run anywhere .NET runs).</summary>
public static class Check
{
    public static void True(bool condition, string message = "expected true")
    {
        if (!condition) throw new AssertionFailed(message);
    }

    public static void False(bool condition, string message = "expected false") => True(!condition, message);

    public static void Equal<T>(T expected, T actual, string? what = null)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new AssertionFailed($"{what ?? "values"}: expected <{expected}> but was <{actual}>");
        }
    }

    public static void Near(double expected, double actual, double tolerance = 1e-9, string? what = null)
    {
        if (Math.Abs(expected - actual) > tolerance)
        {
            throw new AssertionFailed($"{what ?? "value"}: expected {expected} but was {actual} (tolerance {tolerance})");
        }
    }

    public static void SequenceEqual<T>(IEnumerable<T> expected, IEnumerable<T> actual, string? what = null)
    {
        var e = expected.ToList();
        var a = actual.ToList();
        if (!e.SequenceEqual(a))
        {
            throw new AssertionFailed($"{what ?? "sequence"}: expected [{string.Join(", ", e)}] but was [{string.Join(", ", a)}]");
        }
    }

    public static T Throws<T>(Action action) where T : Exception
    {
        try
        {
            action();
        }
        catch (T ex)
        {
            return ex;
        }
        catch (Exception ex)
        {
            throw new AssertionFailed($"expected {typeof(T).Name} but got {ex.GetType().Name}: {ex.Message}");
        }
        throw new AssertionFailed($"expected {typeof(T).Name} but nothing was thrown");
    }
}

public static class Program
{
    public static int Main(string[] args)
    {
        var filter = args.FirstOrDefault();
        var passed = 0;
        var failed = new List<string>();

        var methods = Assembly.GetExecutingAssembly().GetTypes()
            .SelectMany(t => t.GetMethods(BindingFlags.Public | BindingFlags.Static))
            .Where(m => m.GetCustomAttribute<TestAttribute>() != null)
            .OrderBy(m => m.DeclaringType!.Name).ThenBy(m => m.Name)
            .ToList();

        foreach (var method in methods)
        {
            var name = $"{method.DeclaringType!.Name}.{method.Name}";
            if (filter != null && !name.Contains(filter, StringComparison.OrdinalIgnoreCase)) continue;
            try
            {
                var result = method.Invoke(null, null);
                if (result is Task task) task.GetAwaiter().GetResult();
                passed++;
                Console.WriteLine($"  PASS  {name}");
            }
            catch (Exception ex)
            {
                var inner = ex is TargetInvocationException { InnerException: not null } tie ? tie.InnerException! : ex;
                failed.Add($"{name}: {inner.Message}");
                Console.WriteLine($"  FAIL  {name}\n        {inner.Message}");
            }
        }

        Console.WriteLine();
        Console.WriteLine($"{passed} passed, {failed.Count} failed ({passed + failed.Count} total)");
        if (failed.Count > 0)
        {
            Console.WriteLine("Failures:");
            foreach (var f in failed) Console.WriteLine("  - " + f);
            return 1;
        }
        return 0;
    }
}

/// <summary>A performer that records what it was asked to do.</summary>
public sealed class FakePerformer : ActionRecorder.Core.IActionPerformer
{
    public readonly List<ActionRecorder.Core.MacroAction> Performed = new();
    public int Cleanups;
    public int Begins;
    public Action<ActionRecorder.Core.MacroAction>? OnPerform;
    private readonly object _gate = new();

    public void Begin() => Interlocked.Increment(ref Begins);

    public void Perform(ActionRecorder.Core.MacroAction action)
    {
        lock (_gate) Performed.Add(action);
        OnPerform?.Invoke(action);
    }

    public void Cleanup() => Interlocked.Increment(ref Cleanups);

    public int Count
    {
        get { lock (_gate) return Performed.Count; }
    }
}
