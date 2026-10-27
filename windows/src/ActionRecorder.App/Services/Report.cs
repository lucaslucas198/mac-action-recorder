using System.Text;

namespace ActionRecorder.Desktop;

/// <summary>Collects PASS/FAIL lines for the CI test modes and writes them to a file (and the console when there is one).</summary>
internal sealed class Report
{
    private readonly List<string> _lines = new();
    private readonly string? _path;

    public Report(string? path) => _path = path;

    public int Failures { get; private set; }
    public int Passes { get; private set; }

    public void Pass(string name, string detail = "")
    {
        Passes++;
        Add("PASS", name, detail);
    }

    public void Fail(string name, string detail)
    {
        Failures++;
        Add("FAIL", name, detail);
    }

    public void Info(string text) => Add("INFO", text, "");

    public void Check(bool ok, string name, string detailWhenFailed, string detailWhenOk = "")
    {
        if (ok) Pass(name, detailWhenOk);
        else Fail(name, detailWhenFailed);
    }

    private void Add(string status, string name, string detail)
    {
        var line = detail.Length > 0 ? $"{status} {name} :: {detail}" : $"{status} {name}";
        lock (_lines)
        {
            _lines.Add(line);
            Flush();
        }
        try { Console.WriteLine(line); } catch (Exception) { }
    }

    private void Flush()
    {
        if (_path == null) return;
        try
        {
            File.WriteAllText(_path, string.Join(Environment.NewLine, _lines) + Environment.NewLine, Encoding.UTF8);
        }
        catch (Exception)
        {
            // The report is best-effort.
        }
    }
}
