using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace MuteCue.Desktop.Services;

public sealed class NativeSettingsDocument
{
    private const int CurrentSchemaVersion = 5;
    private readonly string _path;
    private JsonObject _root;

    private NativeSettingsDocument(string path, JsonObject root)
    {
        _path = path;
        _root = root;
    }

    public static NativeSettingsDocument Load(string path)
    {
        foreach (var candidate in new[] { path, path + ".bak" })
        {
            try
            {
                if (!File.Exists(candidate) || new FileInfo(candidate).Length > 1024 * 1024)
                {
                    continue;
                }

                var root = JsonNode.Parse(File.ReadAllText(candidate, Encoding.UTF8)) as JsonObject;
                if (root is not null)
                {
                    return new NativeSettingsDocument(path, root);
                }
            }
            catch (JsonException)
            {
                // Fall through to the backup or safe defaults.
            }
            catch (IOException)
            {
                // Fall through to the backup or safe defaults.
            }
        }

        return new NativeSettingsDocument(path, new JsonObject { ["SchemaVersion"] = CurrentSchemaVersion });
    }

    public bool GetBoolean(string name, bool fallback) => TryRead(name, fallback, value => value.GetValue<bool>());

    public int GetInteger(string name, int fallback, int minimum, int maximum) => Math.Clamp(TryRead(name, fallback, value => value.GetValue<int>()), minimum, maximum);

    public double GetDouble(string name, double fallback, double minimum, double maximum)
    {
        var value = TryRead(name, fallback, json => json.GetValue<double>());
        return double.IsFinite(value) ? Math.Clamp(value, minimum, maximum) : fallback;
    }

    public string GetString(string name, string fallback)
    {
        var value = TryRead(name, fallback, json => json.GetValue<string>());
        return value.Length <= 4096 ? value : value[..4096];
    }

    public void SetBoolean(string name, bool value) => _root[name] = value;

    public void SetInteger(string name, int value) => _root[name] = value;

    public void SetDouble(string name, double value) => _root[name] = value;

    public void Save()
    {
        _root["SchemaVersion"] = CurrentSchemaVersion;
        var directory = Path.GetDirectoryName(_path) ?? throw new InvalidOperationException("The settings path must have a directory.");
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(_path)}.{Guid.NewGuid():N}.tmp");
        var backupPath = _path + ".bak";
        var content = _root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });

        File.WriteAllText(temporaryPath, content, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        try
        {
            if (File.Exists(_path))
            {
                File.Copy(_path, backupPath, overwrite: true);
            }

            File.Move(temporaryPath, _path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private T TryRead<T>(string name, T fallback, Func<JsonValue, T> convert)
    {
        try
        {
            return _root[name] is JsonValue value ? convert(value) : fallback;
        }
        catch (InvalidOperationException)
        {
            return fallback;
        }
        catch (FormatException)
        {
            return fallback;
        }
    }
}

public static class FaderSourceParser
{
    public static IReadOnlyList<string> Parse(string value)
    {
        return value.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(32)
            .ToArray();
    }
}
