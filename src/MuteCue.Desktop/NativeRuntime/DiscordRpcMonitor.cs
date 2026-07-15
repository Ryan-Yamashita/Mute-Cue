#pragma warning disable
using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;

namespace BeacnMuteOverlay {
    public sealed class DiscordRpcMonitorEvent {
        public string Kind { get; set; }
        public string Status { get; set; }
        public bool Known { get; set; }
        public bool MicMuted { get; set; }
        public bool Deafened { get; set; }
        public string AccessToken { get; set; }
        public string RefreshToken { get; set; }
        public long ExpiresAtUnixSeconds { get; set; }
    }

    internal sealed class TerminalDiscordException : Exception {
        public TerminalDiscordException(string message) : base(message) { }
    }

    public static class DiscordRpcMonitor {
        private const int MaximumQueuedEvents = 256;
        private static readonly ConcurrentQueue<DiscordRpcMonitorEvent> events = new ConcurrentQueue<DiscordRpcMonitorEvent>();
        private static int queuedEventCount;
        private static readonly object lifecycleLock = new object();
        private static volatile bool stopRequested;
        private static Thread worker;
        private static int runGeneration;
        private static NamedPipeClientStream activePipe;
        private static string currentChannelId;
        private static string currentUserId;
        private static string pendingCodeVerifier;
        private static string pendingRedirectUri;

        public static bool IsRunning {
            get { return worker != null && worker.IsAlive; }
        }

        public static string Start(string applicationId, string redirectUri, string accessToken, string refreshToken, long expiresAtUnixSeconds) {
            if (String.IsNullOrWhiteSpace(applicationId)) return "Discord sign-in is not configured in this build.";
            foreach (char character in applicationId) {
                if (!Char.IsDigit(character)) return "The Discord application ID should contain only numbers.";
            }
            if (String.IsNullOrWhiteSpace(redirectUri)) return "Discord sign-in is not configured in this build.";

            Stop();
            ClearEvents();
            int generation = Interlocked.Increment(ref runGeneration);
            stopRequested = false;
            worker = new Thread(delegate() { Run(applicationId.Trim(), redirectUri.Trim(), accessToken, refreshToken, expiresAtUnixSeconds, generation); });
            worker.IsBackground = true;
            worker.Name = "Discord RPC voice monitor";
            worker.Start();
            return "Connecting to Discord...";
        }

        public static void Stop() {
            Thread workerToJoin;
            lock (lifecycleLock) {
                stopRequested = true;
                Interlocked.Increment(ref runGeneration);
                if (activePipe != null) {
                    try { activePipe.Dispose(); } catch { }
                    activePipe = null;
                }
                workerToJoin = worker;
                worker = null;
                currentChannelId = null;
                currentUserId = null;
            }
            if (workerToJoin != null && workerToJoin.IsAlive && Thread.CurrentThread != workerToJoin) {
                try { workerToJoin.Join(1000); } catch { }
            }
        }

        public static bool TryDequeue(out DiscordRpcMonitorEvent update) {
            if (!events.TryDequeue(out update)) return false;
            Interlocked.Decrement(ref queuedEventCount);
            return true;
        }

        private static void EnqueueEvent(DiscordRpcMonitorEvent update) {
            events.Enqueue(update);
            int count = Interlocked.Increment(ref queuedEventCount);
            while (count > MaximumQueuedEvents) {
                DiscordRpcMonitorEvent discarded;
                if (!events.TryDequeue(out discarded)) break;
                Interlocked.Decrement(ref queuedEventCount);
                count = Volatile.Read(ref queuedEventCount);
            }
        }

        private static void ClearEvents() {
            DiscordRpcMonitorEvent discarded;
            while (events.TryDequeue(out discarded)) { }
            Interlocked.Exchange(ref queuedEventCount, 0);
        }

        private static string CreateCodeVerifier() {
            byte[] bytes = new byte[48];
            using (RandomNumberGenerator generator = RandomNumberGenerator.Create()) generator.GetBytes(bytes);
            return ToBase64Url(bytes);
        }

        private static string CreateCodeChallenge(string verifier) {
            using (SHA256 hash = SHA256.Create()) return ToBase64Url(hash.ComputeHash(Encoding.ASCII.GetBytes(verifier)));
        }

        private static string ToBase64Url(byte[] bytes) {
            return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        }

        private static void Run(string applicationId, string redirectUri, string accessToken, string refreshToken, long expiresAtUnixSeconds, int generation) {
            int retryCount = 0;
            try {
                while (!stopRequested && generation == runGeneration) {
                    try {
                        RunSession(applicationId, redirectUri, ref accessToken, ref refreshToken, ref expiresAtUnixSeconds, generation);
                        retryCount = 0;
                    } catch (TerminalDiscordException error) {
                        if (!stopRequested && generation == runGeneration) EmitStatus(CleanError(error.Message));
                        break;
                    } catch (Exception) {
                        if (stopRequested || generation != runGeneration) break;
                        SetVoiceState(false, false, false);
                        retryCount++;
                        int retrySeconds = Math.Min(15, Math.Max(2, retryCount * 2));
                        EmitStatus("Discord disconnected. Reconnecting in " + retrySeconds + " seconds...");
                        if (!WaitForRetry(retrySeconds, generation)) break;
                    } finally {
                        lock (lifecycleLock) { activePipe = null; }
                    }
                }
            } finally {
                lock (lifecycleLock) { activePipe = null; }
                if (generation == runGeneration) SetVoiceState(false, false, false);
            }
        }

        private static void RunSession(string applicationId, string redirectUri, ref string accessToken, ref string refreshToken, ref long expiresAtUnixSeconds, int generation) {
            currentChannelId = null;
            currentUserId = null;
            pendingCodeVerifier = null;
            pendingRedirectUri = null;
            EmitStatus("Finding Discord's local connection...");
            using (NamedPipeClientStream pipe = OpenPipe(generation)) {
                if (pipe == null) throw new IOException("Discord's local connection was not found.");
                lock (lifecycleLock) { activePipe = pipe; }
                SendFrame(pipe, 0, "{\"v\":1,\"client_id\":" + Quote(applicationId) + "}");
                IDictionary<string, object> ready = ReadPayload(pipe);
                if (!String.Equals(GetString(ready, "evt"), "READY", StringComparison.OrdinalIgnoreCase)) {
                    throw new TerminalDiscordException("Discord did not accept this application ID.");
                }

                if (!String.IsNullOrWhiteSpace(accessToken) && expiresAtUnixSeconds > DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 30) {
                    EmitStatus("Restoring the saved Discord connection...");
                    SendCommand(pipe, "AUTHENTICATE", null, "{\"access_token\":" + Quote(accessToken) + "}");
                } else if (!String.IsNullOrWhiteSpace(refreshToken)) {
                    EmitStatus("Refreshing the saved Discord connection...");
                    string refreshedAccessToken;
                    string refreshedRefreshToken;
                    long refreshedExpiresAt;
                    string refreshError;
                    if (RefreshToken(applicationId, refreshToken, out refreshedAccessToken, out refreshedRefreshToken, out refreshedExpiresAt, out refreshError)) {
                        accessToken = refreshedAccessToken;
                        refreshToken = refreshedRefreshToken;
                        expiresAtUnixSeconds = refreshedExpiresAt;
                        EmitCredentials(accessToken, refreshToken, expiresAtUnixSeconds);
                        SendCommand(pipe, "AUTHENTICATE", null, "{\"access_token\":" + Quote(accessToken) + "}");
                    } else {
                        EmitStatus("Saved Discord connection expired. Waiting for authorization...");
                        BeginAuthorization(pipe, applicationId, redirectUri);
                    }
                } else {
                    EmitStatus("Waiting for Discord authorization...");
                    BeginAuthorization(pipe, applicationId, redirectUri);
                }
                while (!stopRequested && generation == runGeneration) {
                    IDictionary<string, object> payload = ReadPayload(pipe);
                    HandlePayload(pipe, applicationId, redirectUri, payload, ref accessToken, ref refreshToken, ref expiresAtUnixSeconds);
                }
            }
        }

        private static bool WaitForRetry(int seconds, int generation) {
            int slices = Math.Max(1, seconds * 10);
            for (int index = 0; index < slices; index++) {
                if (stopRequested || generation != runGeneration) return false;
                Thread.Sleep(100);
            }
            return !stopRequested && generation == runGeneration;
        }

        private static NamedPipeClientStream OpenPipe(int generation) {
            for (int index = 0; index < 10 && !stopRequested && generation == runGeneration; index++) {
                try {
                    NamedPipeClientStream pipe = new NamedPipeClientStream(".", "discord-ipc-" + index, PipeDirection.InOut, PipeOptions.None);
                    pipe.Connect(350);
                    return pipe;
                } catch {
                }
            }
            return null;
        }

        private static void HandlePayload(NamedPipeClientStream pipe, string applicationId, string redirectUri, IDictionary<string, object> payload, ref string accessToken, ref string refreshToken, ref long expiresAtUnixSeconds) {
            string command = GetString(payload, "cmd");
            string eventName = GetString(payload, "evt");
            IDictionary<string, object> data = AsDictionary(GetValue(payload, "data"));

            if (String.Equals(eventName, "ERROR", StringComparison.OrdinalIgnoreCase)) {
                if (String.Equals(command, "AUTHENTICATE", StringComparison.OrdinalIgnoreCase)) {
                    EmitStatus("Saved Discord connection needs approval. Waiting for authorization...");
                    BeginAuthorization(pipe, applicationId, redirectUri);
                    return;
                }
                string errorMessage = CleanError(GetString(data, "message"));
                throw new TerminalDiscordException("Discord rejected the connection: " + errorMessage);
            }

            if (String.Equals(command, "AUTHORIZE", StringComparison.OrdinalIgnoreCase)) {
                string code = GetString(data, "code");
                if (String.IsNullOrWhiteSpace(code)) {
                    EmitStatus("Discord did not return an authorization code.");
                    return;
                }
                EmitStatus("Discord approved the connection. Signing in...");
                string token;
                string returnedRefreshToken;
                long expiresAt;
                string tokenError;
                if (!ExchangeCode(applicationId, redirectUri, code, out token, out returnedRefreshToken, out expiresAt, out tokenError)) {
                    throw new TerminalDiscordException("Discord sign-in could not finish: " + tokenError);
                }
                accessToken = token;
                refreshToken = returnedRefreshToken;
                expiresAtUnixSeconds = expiresAt;
                EmitCredentials(accessToken, refreshToken, expiresAtUnixSeconds);
                SendCommand(pipe, "AUTHENTICATE", null, "{\"access_token\":" + Quote(accessToken) + "}");
                return;
            }

            if (String.Equals(command, "AUTHENTICATE", StringComparison.OrdinalIgnoreCase)) {
                IDictionary<string, object> user = AsDictionary(GetValue(data, "user"));
                currentUserId = GetString(user, "id");
                if (String.IsNullOrWhiteSpace(currentUserId)) {
                    throw new TerminalDiscordException("Discord did not return the signed-in user.");
                }
                EmitStatus("Discord connected. Watching voice state.");
                SendCommand(pipe, "SUBSCRIBE", "VOICE_CHANNEL_SELECT", "{}");
                SendCommand(pipe, "GET_SELECTED_VOICE_CHANNEL", null, "{}");
                return;
            }

            if (String.Equals(eventName, "VOICE_CHANNEL_SELECT", StringComparison.OrdinalIgnoreCase)) {
                string channelId = GetString(data, "channel_id");
                if (String.IsNullOrWhiteSpace(channelId)) {
                    UnsubscribeCurrentChannel(pipe);
                    SetVoiceState(false, false, false);
                    EmitStatus("Discord connected. Not in a voice channel.");
                } else {
                    SubscribeToChannel(pipe, channelId);
                    SendCommand(pipe, "GET_CHANNEL", null, "{\"channel_id\":" + Quote(channelId) + "}");
                }
                return;
            }

            if (String.Equals(command, "GET_SELECTED_VOICE_CHANNEL", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(command, "GET_CHANNEL", StringComparison.OrdinalIgnoreCase)) {
                string channelId = GetString(data, "id");
                if (String.IsNullOrWhiteSpace(channelId)) {
                    SetVoiceState(false, false, false);
                    EmitStatus("Discord connected. Not in a voice channel.");
                } else {
                    SubscribeToChannel(pipe, channelId);
                    SyncVoiceState(data);
                }
                return;
            }

            if (String.Equals(eventName, "VOICE_STATE_CREATE", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(eventName, "VOICE_STATE_UPDATE", StringComparison.OrdinalIgnoreCase)) {
                IDictionary<string, object> user = AsDictionary(GetValue(data, "user"));
                if (String.Equals(GetString(user, "id"), currentUserId, StringComparison.Ordinal)) {
                    ApplyVoiceState(AsDictionary(GetValue(data, "voice_state")));
                }
                return;
            }

            if (String.Equals(eventName, "VOICE_STATE_DELETE", StringComparison.OrdinalIgnoreCase)) {
                IDictionary<string, object> user = AsDictionary(GetValue(data, "user"));
                if (String.Equals(GetString(user, "id"), currentUserId, StringComparison.Ordinal)) {
                    UnsubscribeCurrentChannel(pipe);
                    SetVoiceState(false, false, false);
                    EmitStatus("Discord connected. Not in a voice channel.");
                }
            }
        }

        private static void SubscribeToChannel(NamedPipeClientStream pipe, string channelId) {
            if (String.Equals(currentChannelId, channelId, StringComparison.Ordinal)) return;
            UnsubscribeCurrentChannel(pipe);
            currentChannelId = channelId;
            string[] names = { "VOICE_STATE_CREATE", "VOICE_STATE_UPDATE", "VOICE_STATE_DELETE" };
            foreach (string name in names) {
                SendCommand(pipe, "SUBSCRIBE", name, "{\"channel_id\":" + Quote(channelId) + "}");
            }
        }

        private static void UnsubscribeCurrentChannel(NamedPipeClientStream pipe) {
            if (String.IsNullOrWhiteSpace(currentChannelId)) return;
            string[] names = { "VOICE_STATE_CREATE", "VOICE_STATE_UPDATE", "VOICE_STATE_DELETE" };
            foreach (string name in names) {
                try { SendCommand(pipe, "UNSUBSCRIBE", name, "{\"channel_id\":" + Quote(currentChannelId) + "}"); } catch { }
            }
            currentChannelId = null;
        }

        private static void SyncVoiceState(IDictionary<string, object> channel) {
            IEnumerable voiceStates = GetValue(channel, "voice_states") as IEnumerable;
            if (voiceStates == null) {
                SetVoiceState(false, false, false);
                return;
            }
            foreach (object item in voiceStates) {
                IDictionary<string, object> entry = AsDictionary(item);
                IDictionary<string, object> user = AsDictionary(GetValue(entry, "user"));
                if (String.Equals(GetString(user, "id"), currentUserId, StringComparison.Ordinal)) {
                    ApplyVoiceState(AsDictionary(GetValue(entry, "voice_state")));
                    return;
                }
            }
            SetVoiceState(false, false, false);
        }

        private static void ApplyVoiceState(IDictionary<string, object> voiceState) {
            SetVoiceState(true, GetBoolean(voiceState, "self_mute"), GetBoolean(voiceState, "self_deaf"));
        }

        private static void SetVoiceState(bool known, bool micMuted, bool deafened) {
            DiscordRpcMonitorEvent update = new DiscordRpcMonitorEvent();
            update.Kind = "state";
            update.Known = known;
            update.MicMuted = micMuted;
            update.Deafened = deafened;
            EnqueueEvent(update);
        }

        private static void BeginAuthorization(Stream pipe, string applicationId, string redirectUri) {
            string verifier = CreateCodeVerifier();
            string challenge = CreateCodeChallenge(verifier);
            SendCommand(pipe, "AUTHORIZE", null, "{\"client_id\":" + Quote(applicationId) + ",\"scopes\":[\"identify\",\"rpc\"],\"code_challenge\":" + Quote(challenge) + ",\"code_challenge_method\":\"S256\"}");
            pendingCodeVerifier = verifier;
            pendingRedirectUri = redirectUri;
        }

        private static void EmitCredentials(string accessToken, string refreshToken, long expiresAtUnixSeconds) {
            DiscordRpcMonitorEvent update = new DiscordRpcMonitorEvent();
            update.Kind = "credentials";
            update.AccessToken = accessToken;
            update.RefreshToken = refreshToken;
            update.ExpiresAtUnixSeconds = expiresAtUnixSeconds;
            EnqueueEvent(update);
        }

        private static void EmitStatus(string status) {
            DiscordRpcMonitorEvent update = new DiscordRpcMonitorEvent();
            update.Kind = "status";
            update.Status = status;
            EnqueueEvent(update);
        }

        private static bool ExchangeCode(string applicationId, string redirectUri, string code, out string token, out string refreshToken, out long expiresAtUnixSeconds, out string error) {
            List<string> values = new List<string>();
            values.Add("grant_type=authorization_code");
            values.Add("code=" + Uri.EscapeDataString(code));
            if (!String.IsNullOrWhiteSpace(redirectUri)) values.Add("redirect_uri=" + Uri.EscapeDataString(redirectUri));
            values.Add("code_verifier=" + Uri.EscapeDataString(pendingCodeVerifier ?? String.Empty));
            return RequestToken(applicationId, values, out token, out refreshToken, out expiresAtUnixSeconds, out error);
        }

        private static bool RefreshToken(string applicationId, string refreshToken, out string token, out string returnedRefreshToken, out long expiresAtUnixSeconds, out string error) {
            List<string> values = new List<string>();
            values.Add("grant_type=refresh_token");
            values.Add("refresh_token=" + Uri.EscapeDataString(refreshToken));
            return RequestToken(applicationId, values, out token, out returnedRefreshToken, out expiresAtUnixSeconds, out error);
        }

        private static bool RequestToken(string applicationId, List<string> values, out string token, out string refreshToken, out long expiresAtUnixSeconds, out string error) {
            token = null;
            refreshToken = null;
            expiresAtUnixSeconds = 0;
            error = null;
            try {
                ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                values.Add("client_id=" + Uri.EscapeDataString(applicationId));
                byte[] body = Encoding.UTF8.GetBytes(String.Join("&", values.ToArray()));
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create("https://discord.com/api/oauth2/token");
                request.Method = "POST";
                request.ContentType = "application/x-www-form-urlencoded";
                request.Accept = "application/json";
                request.UserAgent = "Mute-Cue/1.0";
                request.Timeout = 10000;
                request.ReadWriteTimeout = 10000;
                request.KeepAlive = false;
                request.ContentLength = body.Length;
                using (Stream stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                using (StreamReader reader = new StreamReader(response.GetResponseStream())) {
                    IDictionary<string, object> payload = AsDictionary(ParseJson(reader.ReadToEnd()));
                    token = GetString(payload, "access_token");
                    refreshToken = GetString(payload, "refresh_token");
                    long expiresIn;
                    if (!Int64.TryParse(GetString(payload, "expires_in"), out expiresIn) || expiresIn <= 0) expiresIn = 3600;
                    expiresAtUnixSeconds = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + expiresIn;
                    if (String.IsNullOrWhiteSpace(token)) {
                        error = "Discord did not return an access token.";
                        return false;
                    }
                    return true;
                }
            } catch (WebException webError) {
                error = ReadWebError(webError);
                return false;
            } catch (Exception generalError) {
                error = CleanError(generalError.Message);
                return false;
            }
        }

        private static string ReadWebError(WebException error) {
            try {
                if (error.Response != null) {
                    using (StreamReader reader = new StreamReader(error.Response.GetResponseStream())) {
                        IDictionary<string, object> payload = AsDictionary(ParseJson(reader.ReadToEnd()));
                        string description = GetString(payload, "error_description");
                        if (!String.IsNullOrWhiteSpace(description)) return CleanError(description);
                        string code = GetString(payload, "error");
                        if (!String.IsNullOrWhiteSpace(code)) return CleanError(code);
                    }
                }
            } catch { }
            return CleanError(error.Message);
        }

        private static void SendCommand(Stream stream, string command, string eventName, string args) {
            StringBuilder payload = new StringBuilder();
            payload.Append("{\"cmd\":").Append(Quote(command)).Append(",\"nonce\":").Append(Quote(Guid.NewGuid().ToString()));
            if (!String.IsNullOrWhiteSpace(eventName)) payload.Append(",\"evt\":").Append(Quote(eventName));
            payload.Append(",\"args\":").Append(args).Append("}");
            SendFrame(stream, 1, payload.ToString());
        }

        private static IDictionary<string, object> ReadPayload(Stream stream) {
            while (true) {
                int opcode;
                string json;
                ReadFrame(stream, out opcode, out json);
                if (opcode == 3) {
                    SendFrame(stream, 4, json);
                    continue;
                }
                if (opcode == 2) throw new IOException("Discord closed the local connection.");
                if (opcode != 1) throw new InvalidDataException("Discord sent an unsupported RPC frame.");
                object payload = ParseJson(json);
                IDictionary<string, object> dictionary = AsDictionary(payload);
                if (dictionary == null) throw new InvalidDataException("Discord sent an invalid message.");
                return dictionary;
            }
        }

        private static IDictionary<string, object> AsDictionary(object value) {
            return value as IDictionary<string, object>;
        }

        private static object ParseJson(string json) {
            using (JsonDocument document = JsonDocument.Parse(json)) {
                return ConvertJsonElement(document.RootElement);
            }
        }

        private static object ConvertJsonElement(JsonElement element) {
            switch (element.ValueKind) {
                case JsonValueKind.Object:
                    Dictionary<string, object> dictionary = new Dictionary<string, object>(StringComparer.Ordinal);
                    foreach (JsonProperty property in element.EnumerateObject()) {
                        dictionary[property.Name] = ConvertJsonElement(property.Value);
                    }
                    return dictionary;
                case JsonValueKind.Array:
                    List<object> list = new List<object>();
                    foreach (JsonElement item in element.EnumerateArray()) list.Add(ConvertJsonElement(item));
                    return list;
                case JsonValueKind.String:
                    return element.GetString();
                case JsonValueKind.Number:
                    long integer;
                    return element.TryGetInt64(out integer) ? (object)integer : element.GetDouble();
                case JsonValueKind.True:
                    return true;
                case JsonValueKind.False:
                    return false;
                default:
                    return null;
            }
        }

        private static object GetValue(IDictionary<string, object> dictionary, string key) {
            if (dictionary == null) return null;
            object value;
            return dictionary.TryGetValue(key, out value) ? value : null;
        }

        private static string GetString(IDictionary<string, object> dictionary, string key) {
            object value = GetValue(dictionary, key);
            return value == null ? null : Convert.ToString(value);
        }

        private static bool GetBoolean(IDictionary<string, object> dictionary, string key) {
            object value = GetValue(dictionary, key);
            if (value is bool) return (bool)value;
            bool result;
            return value != null && Boolean.TryParse(Convert.ToString(value), out result) && result;
        }

        private static string Quote(string value) {
            return "\"" + (value ?? String.Empty).Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n") + "\"";
        }

        private static string CleanError(string value) {
            if (String.IsNullOrWhiteSpace(value)) return "Unknown error.";
            return value.Replace("\r", " ").Replace("\n", " ").Trim();
        }

        private static void SendFrame(Stream stream, int opcode, string payload) {
            byte[] body = Encoding.UTF8.GetBytes(payload);
            if (body.Length > 1024 * 1024) throw new InvalidDataException("The Discord RPC request is too large.");
            stream.Write(BitConverter.GetBytes(opcode), 0, 4);
            stream.Write(BitConverter.GetBytes(body.Length), 0, 4);
            stream.Write(body, 0, body.Length);
            stream.Flush();
        }

        private static void ReadFrame(Stream stream, out int opcode, out string payload) {
            byte[] header = ReadExactly(stream, 8);
            opcode = BitConverter.ToInt32(header, 0);
            int length = BitConverter.ToInt32(header, 4);
            if (length < 0 || length > 1024 * 1024) throw new InvalidDataException("Discord sent an invalid response.");
            payload = Encoding.UTF8.GetString(ReadExactly(stream, length));
        }

        private static byte[] ReadExactly(Stream stream, int length) {
            byte[] data = new byte[length];
            int offset = 0;
            while (offset < length) {
                int read = stream.Read(data, offset, length - offset);
                if (read == 0) throw new EndOfStreamException("Discord closed the local connection.");
                offset += read;
            }
            return data;
        }
    }
}
