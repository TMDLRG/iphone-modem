// ModemBridge: the Windows side of the Modem iPhone tether.
//
// Reaches the Modem app on the iPhone over USB through Apple's usbmuxd (part of
// iTunes / Apple Devices, listening on 127.0.0.1:27015) and exposes the phone's
// proxy on 127.0.0.1:1080. In full mode it routes the whole PC through that
// proxy with tun2socks + Wintun, and answers DNS by forwarding it over TCP
// through the phone, so nothing leaves except over the phone's cellular data.
//
// Written for the C# 5 compiler that ships with Windows
// (C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe), so no SDK is needed.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Xml;
using Microsoft.Win32;

namespace ModemBridge
{
    sealed class Options
    {
        public string Mode = "full";            // full | proxy | bridge
        public int LocalPort = 1080;
        public int PhonePort = 1080;
        public bool Dns;                        // DNS forwarder (always on in full mode)
        public int DnsPort = 53;
        public List<string> DnsServers = new List<string> { "1.1.1.1", "8.8.8.8" };
        public string MuxHost = "127.0.0.1";
        public int MuxPort = 27015;
        public string DirectHost;               // testing: skip usbmux and connect here instead
        public int DirectPort;
        public string Tun2Socks;
        public bool NoElevate;
        public bool Elevated;
        public bool RestoreProxy;
    }

    static class Program
    {
        public static Options Opt;
        public static readonly string AppDir = AppDomain.CurrentDomain.BaseDirectory;
        static readonly ManualResetEvent exitSignal = new ManualResetEvent(false);
        static int cleanedUp;
        static NativeMethods.ConsoleCtrlHandler ctrlHandler; // kept alive for the native callback

        static bool ExitRequested { get { return exitSignal.WaitOne(0); } }

        static int Main(string[] args)
        {
            try
            {
                Opt = ParseArgs(args);
            }
            catch (ArgumentException ex)
            {
                Console.Error.WriteLine(ex.Message);
                PrintUsage();
                return 2;
            }

            if (Opt.RestoreProxy)
            {
                SystemProxy.RestoreFromBackup(true);
                return 0;
            }

            if (Opt.Mode == "full" && !IsAdmin())
            {
                if (Opt.NoElevate)
                {
                    Log.Error("Full mode needs administrator rights because it creates a network adapter.");
                    return 1;
                }
                return RelaunchElevated(args);
            }

            try { Console.Title = "Modem Bridge (" + Opt.Mode + " mode)"; } catch (IOException) { }
            ThreadPool.SetMinThreads(64, 64);
            ctrlHandler = OnConsoleCtrl;
            NativeMethods.SetConsoleCtrlHandler(ctrlHandler, true);

            int code;
            try
            {
                SystemProxy.RestoreFromBackup(false); // repairs the proxy setting if a previous run was killed
                code = Run();
            }
            catch (Exception ex)
            {
                Log.Error(ex.Message);
                code = 1;
            }
            finally
            {
                Cleanup();
            }

            if (Opt.Elevated)
            {
                Console.WriteLine();
                Console.WriteLine("Press Enter to close this window.");
                Console.ReadLine();
            }
            return code;
        }

        static int Run()
        {
            Log.Info("Modem Bridge starting in " + Opt.Mode + " mode.");
            UsbMux.Host = Opt.MuxHost;
            UsbMux.Port = Opt.MuxPort;
            var phone = new PhoneLink(Opt);

            if (!WaitForPhone(phone)) return 0;

            var forwarder = new Forwarder(phone, Opt.LocalPort);
            forwarder.Start();
            Log.Ok("Phone proxy available at 127.0.0.1:" + Opt.LocalPort + " (SOCKS5 and HTTP).");

            if (Opt.Mode == "full" || Opt.Dns)
            {
                var dns = new DnsForwarder(phone, Opt.DnsServers, Opt.DnsPort);
                dns.Start();
                Log.Ok("DNS on 127.0.0.1:" + Opt.DnsPort + " is answered by " + string.Join(", ", Opt.DnsServers) + " through the phone.");
            }

            if (Opt.Mode == "full")
            {
                Tunnel.Start(Opt);
                Log.Ok("All PC traffic now goes out through the iPhone's cellular data.");
            }
            else if (Opt.Mode == "proxy")
            {
                SystemProxy.Enable("127.0.0.1:" + Opt.LocalPort);
                Log.Ok("Windows proxy set to 127.0.0.1:" + Opt.LocalPort + ". Browsers and most apps now go through the iPhone.");
            }

            Log.Info("Leave this window open. Press Ctrl+C to disconnect.");
            WatchLoop(phone);
            return 0;
        }

        static bool WaitForPhone(PhoneLink phone)
        {
            string last = null;
            while (!ExitRequested)
            {
                string problem = phone.Probe();
                if (problem == null)
                {
                    Log.Ok("Found the Modem app on the iPhone" + (phone.Serial != null ? " (" + phone.Serial + ")" : "") + ".");
                    return true;
                }
                if (problem != last)
                {
                    Log.Warn(problem);
                    Log.Info("Waiting for the iPhone... (Ctrl+C to quit)");
                    last = problem;
                }
                exitSignal.WaitOne(2000);
            }
            return false;
        }

        static void WatchLoop(PhoneLink phone)
        {
            string lastProblem = null;
            string lastLine = null;
            int tick = 0;
            while (!exitSignal.WaitOne(1000))
            {
                tick++;
                if (Tunnel.HasExited)
                {
                    Log.Error("tun2socks stopped unexpectedly. Disconnecting.");
                    return;
                }
                if (tick % 10 != 0) continue;

                string problem = phone.Probe();
                if (problem != lastProblem)
                {
                    if (problem == null) Log.Ok("Phone link is back."); else Log.Warn(problem);
                    lastProblem = problem;
                }
                string line = string.Format(CultureInfo.InvariantCulture,
                    "Open connections {0} | sent {1} | received {2} | DNS answers {3}",
                    Thread.VolatileRead(ref Stats.Active),
                    Fmt.Bytes(Interlocked.Read(ref Stats.Up)),
                    Fmt.Bytes(Interlocked.Read(ref Stats.Down)),
                    Interlocked.Read(ref Stats.DnsAnswers));
                if (line != lastLine)
                {
                    Log.Info(line);
                    lastLine = line;
                }
            }
        }

        static bool OnConsoleCtrl(int type)
        {
            Log.Info("Disconnecting...");
            exitSignal.Set();
            Cleanup();
            // Ctrl+C / Ctrl+Break: handled here, Main finishes normally.
            // Window closed / logoff / shutdown: let Windows end the process.
            return type == 0 || type == 1;
        }

        static void Cleanup()
        {
            if (Interlocked.Exchange(ref cleanedUp, 1) == 1) return;
            try { Tunnel.Stop(); }
            catch (Exception ex) { Log.Warn("Could not stop tun2socks cleanly: " + ex.Message); }
            try { SystemProxy.RestoreFromBackup(false); }
            catch (Exception ex) { Log.Warn("Could not restore the Windows proxy setting: " + ex.Message); }
        }

        static bool IsAdmin()
        {
            var principal = new WindowsPrincipal(WindowsIdentity.GetCurrent());
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }

        static int RelaunchElevated(string[] args)
        {
            var psi = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, QuoteArgs(args) + " --elevated");
            psi.UseShellExecute = true;
            psi.Verb = "runas";
            psi.WorkingDirectory = AppDir;
            try
            {
                Process.Start(psi);
                Log.Info("Opened an administrator window for full mode. This window can close.");
                return 0;
            }
            catch (Win32Exception)
            {
                Log.Error("Administrator permission was declined. Full mode needs it; \"Start Modem (proxy only).cmd\" works without it.");
                return 1;
            }
        }

        static string QuoteArgs(string[] args)
        {
            var parts = new List<string>();
            foreach (var a in args)
            {
                if (a.Length > 0 && a.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) parts.Add(a);
                else parts.Add("\"" + a.Replace("\"", "\\\"") + "\"");
            }
            return string.Join(" ", parts);
        }

        static Options ParseArgs(string[] args)
        {
            var o = new Options();
            for (int i = 0; i < args.Length; i++)
            {
                switch (args[i].ToLowerInvariant())
                {
                    case "--mode": o.Mode = Next(args, ref i).ToLowerInvariant(); break;
                    case "--port": o.LocalPort = ParsePort(Next(args, ref i)); break;
                    case "--phone-port": o.PhonePort = ParsePort(Next(args, ref i)); break;
                    case "--dns": o.Dns = true; break;
                    case "--dns-port": o.DnsPort = ParsePort(Next(args, ref i)); break;
                    case "--dns-servers":
                        o.DnsServers = Next(args, ref i).Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)
                            .Select(s => s.Trim()).Where(s => s.Length > 0).ToList();
                        break;
                    case "--usbmux":
                        {
                            var hp = ParseHostPort(Next(args, ref i));
                            o.MuxHost = hp.Key;
                            o.MuxPort = hp.Value;
                            break;
                        }
                    case "--direct":
                        {
                            var hp = ParseHostPort(Next(args, ref i));
                            o.DirectHost = hp.Key;
                            o.DirectPort = hp.Value;
                            break;
                        }
                    case "--tun2socks": o.Tun2Socks = Next(args, ref i); break;
                    case "--no-elevate": o.NoElevate = true; break;
                    case "--elevated": o.Elevated = true; break;
                    case "--restore-proxy": o.RestoreProxy = true; break;
                    case "-h":
                    case "--help":
                    case "/?":
                        PrintUsage();
                        Environment.Exit(0);
                        break;
                    default:
                        throw new ArgumentException("Unknown option: " + args[i]);
                }
            }
            if (o.Mode != "full" && o.Mode != "proxy" && o.Mode != "bridge")
                throw new ArgumentException("--mode must be full, proxy or bridge.");
            if (o.DnsServers.Count == 0)
                throw new ArgumentException("--dns-servers needs at least one address.");
            return o;
        }

        static string Next(string[] args, ref int i)
        {
            if (i + 1 >= args.Length) throw new ArgumentException(args[i] + " needs a value.");
            i++;
            return args[i];
        }

        static int ParsePort(string text)
        {
            int port;
            if (!int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out port) || port < 1 || port > 65535)
                throw new ArgumentException("Not a valid port: " + text);
            return port;
        }

        static KeyValuePair<string, int> ParseHostPort(string text)
        {
            int colon = text.LastIndexOf(':');
            if (colon <= 0) throw new ArgumentException("Expected host:port, got " + text);
            return new KeyValuePair<string, int>(text.Substring(0, colon), ParsePort(text.Substring(colon + 1)));
        }

        static void PrintUsage()
        {
            Console.WriteLine(@"
ModemBridge - share the iPhone's cellular data with this PC over USB.

  ModemBridge.exe [--mode full|proxy|bridge] [options]

Modes:
  full    (default) Route the whole PC through the phone. Needs admin
          (asks for it), plus tools\tun2socks.exe and tools\wintun.dll.
  proxy   Set the Windows proxy to the phone. No admin needed; covers
          browsers and apps that honour the system proxy.
  bridge  Only expose the phone's proxy on 127.0.0.1:<port>.

Options:
  --port N             Local proxy port (default 1080)
  --phone-port N       Port the iPhone app listens on (default 1080)
  --dns                Also run the DNS forwarder (always on in full mode)
  --dns-port N         Local DNS port (default 53)
  --dns-servers a,b    DNS servers reached through the phone (default 1.1.1.1,8.8.8.8)
  --usbmux host:port   Where usbmuxd listens (default 127.0.0.1:27015)
  --tun2socks PATH     Path to tun2socks.exe (default tools\tun2socks.exe)
  --restore-proxy      Put back the Windows proxy setting saved by proxy mode
  --no-elevate         Fail instead of asking for admin rights
");
        }
    }

    // ------------------------------------------------------------------ phone

    sealed class PhoneException : Exception
    {
        public PhoneException(string message) : base(message) { }
    }

    sealed class PhoneLink
    {
        readonly Options opt;
        readonly object gate = new object();
        int deviceId = -1;
        public string Serial;

        public PhoneLink(Options opt)
        {
            this.opt = opt;
        }

        /// Opens a fresh TCP stream to the app's port on the iPhone.
        public Socket Open()
        {
            if (opt.DirectHost != null)
            {
                var direct = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                direct.NoDelay = true;
                try { direct.Connect(opt.DirectHost, opt.DirectPort); }
                catch { Net.Close(direct); throw; }
                return direct;
            }
            int id = DeviceId(false);
            try
            {
                return UsbMux.Connect(id, opt.PhonePort);
            }
            catch (UsbMuxException ex)
            {
                if (ex.Code != UsbMuxException.BadDevice) throw;
                return UsbMux.Connect(DeviceId(true), opt.PhonePort); // re-plugged: new device id
            }
        }

        int DeviceId(bool refresh)
        {
            lock (gate)
            {
                if (deviceId >= 0 && !refresh) return deviceId;
                deviceId = -1;
                var devices = UsbMux.ListDevices();
                var usb = devices.FirstOrDefault(d => d.ConnectionType == "USB")
                       ?? devices.FirstOrDefault(d => string.IsNullOrEmpty(d.ConnectionType));
                if (usb == null)
                {
                    throw new PhoneException(devices.Count > 0
                        ? "The iPhone is only visible over Wi-Fi. Connect it with a USB cable."
                        : "No iPhone found on USB. Plug it in, unlock it, and tap Trust if it asks.");
                }
                deviceId = usb.DeviceId;
                Serial = usb.Serial;
                return deviceId;
            }
        }

        /// Returns null when the app answers a SOCKS5 greeting, else a human-readable problem.
        public string Probe()
        {
            Socket s = null;
            try
            {
                s = Open();
                s.ReceiveTimeout = 5000;
                s.SendTimeout = 5000;
                Net.SendAll(s, new byte[] { 5, 1, 0 });
                var reply = Net.ReadExact(s, 2);
                if (reply[0] != 5 || reply[1] != 0)
                    return "Something answered on the iPhone's port " + opt.PhonePort + ", but it is not the Modem app.";
                return null;
            }
            catch (Exception ex)
            {
                if (opt.DirectHost != null && ex is SocketException)
                    return "Nothing is listening at " + opt.DirectHost + ":" + opt.DirectPort + ".";
                return Explain(ex);
            }
            finally
            {
                Net.Close(s);
            }
        }

        public static string Explain(Exception ex)
        {
            if (ex == null) return "unknown error";
            var mux = ex as UsbMuxException;
            if (mux != null)
            {
                if (mux.Code == UsbMuxException.ConnectionRefused)
                    return "The iPhone is connected, but the Modem app is not answering. Open Modem on the iPhone and make sure tethering is on.";
                if (mux.Code == UsbMuxException.BadDevice)
                    return "The iPhone was disconnected. Plug it back in.";
                return "USB connection to the iPhone failed (usbmux error " + mux.Code + ").";
            }
            if (ex is PhoneException) return ex.Message;
            var socketError = ex as SocketException ?? ex.InnerException as SocketException;
            if (socketError != null && socketError.SocketErrorCode == SocketError.TimedOut)
                return "The iPhone did not answer in time. Is the Modem app still open?";
            if (ex is IOException && ex.Message == "closed")
                return "The iPhone closed the connection. Is the Modem app still open?";
            return ex.Message;
        }
    }

    // ----------------------------------------------------------------- usbmux

    sealed class MuxDevice
    {
        public int DeviceId;
        public string ConnectionType;
        public string Serial;
    }

    sealed class UsbMuxException : Exception
    {
        public const int BadDevice = 2;
        public const int ConnectionRefused = 3;
        public readonly int Code;

        public UsbMuxException(int code) : base("usbmux error " + code)
        {
            Code = code;
        }
    }

    /// Minimal client for Apple's usbmuxd protocol (plist flavour).
    static class UsbMux
    {
        public static string Host = "127.0.0.1";
        public static int Port = 27015;
        static int tag;

        public static List<MuxDevice> ListDevices()
        {
            using (var s = OpenMux())
            {
                Send(s, Message("ListDevices"));
                var reply = Receive(s);
                var result = new List<MuxDevice>();
                object listObj;
                if (reply == null || !reply.TryGetValue("DeviceList", out listObj)) return result;
                var list = listObj as List<object>;
                if (list == null) return result;
                foreach (var entry in list)
                {
                    var dev = entry as Dictionary<string, object>;
                    if (dev == null) continue;
                    object propsObj;
                    dev.TryGetValue("Properties", out propsObj);
                    var props = propsObj as Dictionary<string, object> ?? dev;
                    object id;
                    if (!props.TryGetValue("DeviceID", out id) && !dev.TryGetValue("DeviceID", out id)) continue;
                    var device = new MuxDevice();
                    device.DeviceId = Convert.ToInt32(id, CultureInfo.InvariantCulture);
                    device.ConnectionType = Text(props, "ConnectionType");
                    device.Serial = Text(props, "SerialNumber");
                    result.Add(device);
                }
                return result;
            }
        }

        /// Asks usbmuxd for a TCP stream to `port` on the device. On success the
        /// socket becomes a raw pipe to that port.
        public static Socket Connect(int deviceId, int port)
        {
            var s = OpenMux();
            try
            {
                var message = Message("Connect");
                message["DeviceID"] = deviceId;
                message["PortNumber"] = ((port & 0xFF) << 8) | ((port >> 8) & 0xFF); // network byte order
                Send(s, message);
                var reply = Receive(s);
                object number;
                long code = reply != null && reply.TryGetValue("Number", out number)
                    ? Convert.ToInt64(number, CultureInfo.InvariantCulture)
                    : -1;
                if (code != 0) throw new UsbMuxException((int)code);
                s.ReceiveTimeout = 0;
                s.SendTimeout = 0;
                return s;
            }
            catch
            {
                Net.Close(s);
                throw;
            }
        }

        static Socket OpenMux()
        {
            var s = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            s.NoDelay = true;
            s.ReceiveTimeout = 5000;
            s.SendTimeout = 5000;
            try
            {
                s.Connect(Host, Port);
            }
            catch (SocketException)
            {
                Net.Close(s);
                throw new PhoneException("Can't reach Apple Mobile Device Service at " + Host + ":" + Port
                    + ". Install iTunes from apple.com (or the Apple Devices app), then plug in the iPhone.");
            }
            return s;
        }

        static Dictionary<string, object> Message(string type)
        {
            var m = new Dictionary<string, object>();
            m["MessageType"] = type;
            m["ClientVersionString"] = "ModemBridge 1.0";
            m["ProgName"] = "ModemBridge";
            m["kLibUSBMuxVersion"] = 3;
            return m;
        }

        static void Send(Socket s, Dictionary<string, object> message)
        {
            byte[] body = Encoding.UTF8.GetBytes(Plist.Write(message));
            var packet = new byte[16 + body.Length];
            PutInt32(packet, 0, packet.Length);
            PutInt32(packet, 4, 1);                          // protocol version 1 = plist
            PutInt32(packet, 8, 8);                          // message type 8 = plist
            PutInt32(packet, 12, Interlocked.Increment(ref tag));
            Buffer.BlockCopy(body, 0, packet, 16, body.Length);
            Net.SendAll(s, packet);
        }

        static Dictionary<string, object> Receive(Socket s)
        {
            byte[] header = Net.ReadExact(s, 16);
            int length = header[0] | (header[1] << 8) | (header[2] << 16) | (header[3] << 24);
            if (length < 16 || length > 4 * 1024 * 1024) throw new IOException("Invalid reply from usbmuxd.");
            byte[] body = Net.ReadExact(s, length - 16);
            return Plist.Read(body) as Dictionary<string, object>;
        }

        static void PutInt32(byte[] buffer, int offset, int value)
        {
            buffer[offset] = (byte)value;
            buffer[offset + 1] = (byte)(value >> 8);
            buffer[offset + 2] = (byte)(value >> 16);
            buffer[offset + 3] = (byte)(value >> 24);
        }

        static string Text(Dictionary<string, object> d, string key)
        {
            object v;
            return d.TryGetValue(key, out v) && v != null ? Convert.ToString(v, CultureInfo.InvariantCulture) : null;
        }
    }

    /// Just enough XML property list support for usbmuxd messages.
    static class Plist
    {
        public static string Write(Dictionary<string, object> dict)
        {
            var sb = new StringBuilder();
            sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
            sb.Append("<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n");
            sb.Append("<plist version=\"1.0\">\n");
            WriteValue(sb, dict);
            sb.Append("\n</plist>\n");
            return sb.ToString();
        }

        static void WriteValue(StringBuilder sb, object value)
        {
            var dict = value as Dictionary<string, object>;
            if (dict != null)
            {
                sb.Append("<dict>");
                foreach (var pair in dict)
                {
                    sb.Append("<key>").Append(SecurityElement.Escape(pair.Key)).Append("</key>");
                    WriteValue(sb, pair.Value);
                }
                sb.Append("</dict>");
            }
            else if (value is string)
            {
                sb.Append("<string>").Append(SecurityElement.Escape((string)value)).Append("</string>");
            }
            else if (value is int || value is long)
            {
                sb.Append("<integer>").Append(Convert.ToInt64(value).ToString(CultureInfo.InvariantCulture)).Append("</integer>");
            }
            else if (value is bool)
            {
                sb.Append((bool)value ? "<true/>" : "<false/>");
            }
            else
            {
                throw new ArgumentException("Unsupported plist value: " + value);
            }
        }

        public static object Read(byte[] data)
        {
            var settings = new XmlReaderSettings();
            settings.DtdProcessing = DtdProcessing.Ignore;
            settings.XmlResolver = null;
            using (var reader = XmlReader.Create(new MemoryStream(data), settings))
            {
                var doc = new XmlDocument();
                doc.XmlResolver = null;
                doc.Load(reader);
                foreach (XmlNode node in doc.DocumentElement.ChildNodes)
                {
                    var element = node as XmlElement;
                    if (element != null) return ParseElement(element);
                }
                return null;
            }
        }

        static object ParseElement(XmlElement e)
        {
            switch (e.Name)
            {
                case "dict":
                    {
                        var dict = new Dictionary<string, object>();
                        string key = null;
                        foreach (XmlNode node in e.ChildNodes)
                        {
                            var child = node as XmlElement;
                            if (child == null) continue;
                            if (child.Name == "key") key = child.InnerText;
                            else if (key != null) { dict[key] = ParseElement(child); key = null; }
                        }
                        return dict;
                    }
                case "array":
                    {
                        var list = new List<object>();
                        foreach (XmlNode node in e.ChildNodes)
                        {
                            var child = node as XmlElement;
                            if (child != null) list.Add(ParseElement(child));
                        }
                        return list;
                    }
                case "integer":
                    return long.Parse(e.InnerText.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture);
                case "real":
                    return double.Parse(e.InnerText.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture);
                case "true":
                    return true;
                case "false":
                    return false;
                case "data":
                    return Convert.FromBase64String(new string(e.InnerText.Where(c => !char.IsWhiteSpace(c)).ToArray()));
                default:
                    return e.InnerText; // string, date
            }
        }
    }

    // -------------------------------------------------------------- forwarding

    static class Stats
    {
        public static int Active;
        public static long Up;
        public static long Down;
        public static long DnsAnswers;
    }

    static class Net
    {
        public static byte[] ReadExact(Socket s, int count)
        {
            var buffer = new byte[count];
            int offset = 0;
            while (offset < count)
            {
                int n = s.Receive(buffer, offset, count - offset, SocketFlags.None);
                if (n <= 0) throw new IOException("closed");
                offset += n;
            }
            return buffer;
        }

        public static void SendAll(Socket s, byte[] data)
        {
            int offset = 0;
            while (offset < data.Length)
                offset += s.Send(data, offset, data.Length - offset, SocketFlags.None);
        }

        public static void Close(Socket s)
        {
            if (s == null) return;
            try { s.Close(); } catch { }
        }

        /// Copies bytes both ways until both sides have finished, passing half-closes along.
        public static async Task Relay(Socket local, Socket phone)
        {
            Interlocked.Increment(ref Stats.Active);
            try
            {
                await Task.WhenAll(Pump(local, phone, true), Pump(phone, local, false)).ConfigureAwait(false);
            }
            finally
            {
                Close(local);
                Close(phone);
                Interlocked.Decrement(ref Stats.Active);
            }
        }

        static async Task Pump(Socket source, Socket destination, bool upload)
        {
            var input = new NetworkStream(source, false);
            var output = new NetworkStream(destination, false);
            var buffer = new byte[64 * 1024];
            try
            {
                while (true)
                {
                    int n = await input.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                    if (n <= 0) break;
                    await output.WriteAsync(buffer, 0, n).ConfigureAwait(false);
                    if (upload) Interlocked.Add(ref Stats.Up, n); else Interlocked.Add(ref Stats.Down, n);
                }
                try { destination.Shutdown(SocketShutdown.Send); } catch { }
            }
            catch
            {
                // One side broke: tear down both directions.
                Close(source);
                Close(destination);
            }
        }
    }

    /// Accepts local connections on 127.0.0.1:port and pipes each one to the phone.
    sealed class Forwarder
    {
        readonly PhoneLink phone;
        readonly int port;
        TcpListener listener;

        public Forwarder(PhoneLink phone, int port)
        {
            this.phone = phone;
            this.port = port;
        }

        public void Start()
        {
            listener = new TcpListener(IPAddress.Loopback, port);
            listener.ExclusiveAddressUse = true;
            try
            {
                listener.Start(512);
            }
            catch (SocketException ex)
            {
                throw new Exception("Port " + port + " on this PC is already in use (" + ex.Message + "). Close the other program or use --port.");
            }
            var loop = AcceptLoop();
        }

        async Task AcceptLoop()
        {
            while (true)
            {
                Socket client;
                try
                {
                    client = await listener.AcceptSocketAsync().ConfigureAwait(false);
                }
                catch (ObjectDisposedException) { return; }
                catch (SocketException) { continue; }
                client.NoDelay = true;
                var accepted = client;
                var ignored = Task.Run(() => Handle(accepted));
            }
        }

        async Task Handle(Socket client)
        {
            Socket remote;
            try
            {
                remote = await Task.Run(() => phone.Open()).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                Log.Throttled("forward", "Could not open a connection to the phone: " + PhoneLink.Explain(ex));
                Net.Close(client);
                return;
            }
            await Net.Relay(client, remote).ConfigureAwait(false);
        }
    }

    static class Socks
    {
        /// SOCKS5 CONNECT on an already-open stream to the phone.
        public static void Connect(Socket s, string host, int port)
        {
            Net.SendAll(s, new byte[] { 5, 1, 0 });
            var hello = Net.ReadExact(s, 2);
            if (hello[0] != 5 || hello[1] != 0) throw new IOException("The phone refused the proxy handshake.");

            var request = new List<byte> { 5, 1, 0 };
            IPAddress ip;
            if (IPAddress.TryParse(host, out ip) && ip.AddressFamily == AddressFamily.InterNetwork)
            {
                request.Add(1);
                request.AddRange(ip.GetAddressBytes());
            }
            else if (ip != null && ip.AddressFamily == AddressFamily.InterNetworkV6)
            {
                request.Add(4);
                request.AddRange(ip.GetAddressBytes());
            }
            else
            {
                var name = Encoding.ASCII.GetBytes(host);
                request.Add(3);
                request.Add((byte)name.Length);
                request.AddRange(name);
            }
            request.Add((byte)(port >> 8));
            request.Add((byte)(port & 0xFF));
            Net.SendAll(s, request.ToArray());

            var head = Net.ReadExact(s, 4);
            if (head[1] != 0) throw new IOException("The phone could not reach " + host + ":" + port + " (SOCKS error " + head[1] + ").");
            int rest;
            switch (head[3])
            {
                case 1: rest = 4 + 2; break;
                case 4: rest = 16 + 2; break;
                case 3: rest = Net.ReadExact(s, 1)[0] + 2; break;
                default: throw new IOException("Malformed SOCKS reply from the phone.");
            }
            Net.ReadExact(s, rest);
        }
    }

    /// Answers DNS on 127.0.0.1 by sending each query over TCP through the
    /// phone. UDP cannot cross the USB link, but DNS over TCP can.
    sealed class DnsForwarder
    {
        readonly PhoneLink phone;
        readonly List<string> servers;
        readonly int port;
        UdpClient udp;
        TcpListener tcp;

        public DnsForwarder(PhoneLink phone, List<string> servers, int port)
        {
            this.phone = phone;
            this.servers = servers;
            this.port = port;
        }

        public void Start()
        {
            try
            {
                udp = new UdpClient(new IPEndPoint(IPAddress.Loopback, port));
                tcp = new TcpListener(IPAddress.Loopback, port);
                tcp.Start(64);
            }
            catch (SocketException ex)
            {
                throw new Exception("Could not listen for DNS on 127.0.0.1:" + port + " (" + ex.Message + "). Another DNS program may be running.");
            }
            const int SIO_UDP_CONNRESET = -1744830452;
            try { udp.Client.IOControl(SIO_UDP_CONNRESET, new byte[] { 0, 0, 0, 0 }, null); } catch { }
            var a = UdpLoop();
            var b = TcpLoop();
        }

        async Task UdpLoop()
        {
            while (true)
            {
                UdpReceiveResult received;
                try
                {
                    received = await udp.ReceiveAsync().ConfigureAwait(false);
                }
                catch (ObjectDisposedException) { return; }
                catch (SocketException) { continue; }
                var query = received.Buffer;
                var from = received.RemoteEndPoint;
                if (query.Length < 12) continue;
                var ignored = Task.Run(() =>
                {
                    byte[] answer = Resolve(query);
                    try { udp.Send(answer, answer.Length, from); } catch { }
                });
            }
        }

        byte[] Resolve(byte[] query)
        {
            Exception last = null;
            foreach (var server in servers)
            {
                Socket s = null;
                try
                {
                    s = OpenTo(server);
                    var framed = new byte[query.Length + 2];
                    framed[0] = (byte)(query.Length >> 8);
                    framed[1] = (byte)(query.Length & 0xFF);
                    Buffer.BlockCopy(query, 0, framed, 2, query.Length);
                    Net.SendAll(s, framed);
                    var lengthBytes = Net.ReadExact(s, 2);
                    var answer = Net.ReadExact(s, (lengthBytes[0] << 8) | lengthBytes[1]);
                    Interlocked.Increment(ref Stats.DnsAnswers);
                    return answer;
                }
                catch (Exception ex)
                {
                    last = ex;
                }
                finally
                {
                    Net.Close(s);
                }
            }
            Log.Throttled("dns", "DNS lookup failed: " + PhoneLink.Explain(last));
            return ServerFailure(query);
        }

        Socket OpenTo(string server)
        {
            Socket s = phone.Open();
            try
            {
                s.ReceiveTimeout = 8000;
                s.SendTimeout = 8000;
                Socks.Connect(s, server, 53);
                return s;
            }
            catch
            {
                Net.Close(s);
                throw;
            }
        }

        static byte[] ServerFailure(byte[] query)
        {
            var reply = (byte[])query.Clone();
            reply[2] = (byte)(reply[2] | 0x80);   // QR: this is a response
            reply[3] = (byte)(0x80 | 0x02);       // RA set, RCODE 2 = SERVFAIL
            return reply;
        }

        async Task TcpLoop()
        {
            while (true)
            {
                Socket client;
                try
                {
                    client = await tcp.AcceptSocketAsync().ConfigureAwait(false);
                }
                catch (ObjectDisposedException) { return; }
                catch (SocketException) { continue; }
                var accepted = client;
                var ignored = Task.Run(() => HandleTcp(accepted));
            }
        }

        async Task HandleTcp(Socket client)
        {
            Socket remote = null;
            foreach (var server in servers)
            {
                try
                {
                    var target = server;
                    remote = await Task.Run(() => OpenTo(target)).ConfigureAwait(false);
                    break;
                }
                catch (Exception ex)
                {
                    Log.Throttled("dns-tcp", "DNS over TCP failed: " + PhoneLink.Explain(ex));
                }
            }
            if (remote == null)
            {
                Net.Close(client);
                return;
            }
            remote.ReceiveTimeout = 0;
            remote.SendTimeout = 0;
            await Net.Relay(client, remote).ConfigureAwait(false);
        }
    }

    // ------------------------------------------------------------ full mode

    /// Runs tun2socks so every app on the PC goes through the phone.
    static class Tunnel
    {
        public const string AdapterName = "ModemTether";
        const string AdapterAddress = "198.18.77.1";
        static Process process;

        public static bool HasExited
        {
            get
            {
                var p = process;
                return p != null && p.HasExited;
            }
        }

        public static void Start(Options opt)
        {
            string exe = opt.Tun2Socks ?? Path.Combine(Program.AppDir, "tools", "tun2socks.exe");
            if (!File.Exists(exe))
                throw new Exception("tun2socks.exe not found at " + exe + ". Run setup.ps1 first.");
            if (!File.Exists(Path.Combine(Path.GetDirectoryName(exe), "wintun.dll")))
                throw new Exception("wintun.dll must be next to tun2socks.exe. Run setup.ps1 first.");
            if (AdapterExists())
                Log.Warn("A " + AdapterName + " adapter already exists; another copy of Modem Bridge may be running.");

            var psi = new ProcessStartInfo(exe,
                "--device " + AdapterName + " --proxy socks5://127.0.0.1:" + opt.LocalPort + " --loglevel error");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.WorkingDirectory = Path.GetDirectoryName(exe);

            var p = new Process();
            p.StartInfo = psi;
            p.OutputDataReceived += (sender, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) Log.Info("[tun2socks] " + e.Data); };
            p.ErrorDataReceived += (sender, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) Log.Warn("[tun2socks] " + e.Data); };
            p.Start();
            Job.Add(p); // tun2socks dies with this window, taking its routes with it
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            process = p;
            Log.Info("Started tun2socks; waiting for the " + AdapterName + " network adapter...");

            var deadline = DateTime.UtcNow.AddSeconds(20);
            while (!AdapterExists())
            {
                if (p.HasExited) throw new Exception("tun2socks exited (code " + p.ExitCode + ") before creating its adapter.");
                if (DateTime.UtcNow > deadline) throw new Exception("The " + AdapterName + " adapter never appeared.");
                Thread.Sleep(200);
            }

            string name = "\"" + AdapterName + "\"";
            Netsh("interface ipv4 set address name=" + name + " source=static address=" + AdapterAddress + " mask=255.255.255.0 store=active");
            Netsh("interface ipv4 set dnsservers name=" + name + " source=static address=127.0.0.1 register=none validate=no");
            Netsh("interface ipv4 set interface interface=" + name + " metric=1 store=active");
            Netsh("interface ipv4 add route prefix=0.0.0.0/0 interface=" + name + " nexthop=" + AdapterAddress + " metric=1 store=active");
            string ignored;
            Exec("ipconfig", "/flushdns", out ignored);
        }

        public static void Stop()
        {
            var p = process;
            process = null;
            if (p == null) return;
            try
            {
                if (!p.HasExited)
                {
                    p.Kill();
                    p.WaitForExit(5000);
                }
            }
            catch { }
            string ignored;
            Exec("ipconfig", "/flushdns", out ignored);
            Log.Info("Removed the " + AdapterName + " adapter. Windows networking is back to normal.");
        }

        static bool AdapterExists()
        {
            return NetworkInterface.GetAllNetworkInterfaces()
                .Any(n => string.Equals(n.Name, AdapterName, StringComparison.OrdinalIgnoreCase));
        }

        static void Netsh(string arguments)
        {
            string output = null;
            for (int attempt = 0; attempt < 10; attempt++)
            {
                if (Exec("netsh", arguments, out output) == 0) return;
                Thread.Sleep(500);
            }
            throw new Exception("netsh " + arguments + " failed: " + (output ?? "").Trim());
        }

        static int Exec(string file, string arguments, out string output)
        {
            var psi = new ProcessStartInfo(file, arguments);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            using (var p = Process.Start(psi))
            {
                var stderr = p.StandardError.ReadToEndAsync();
                string stdout = p.StandardOutput.ReadToEnd();
                p.WaitForExit();
                output = stdout + stderr.Result;
                return p.ExitCode;
            }
        }
    }

    /// Kill-on-close job object so child processes never outlive us.
    static class Job
    {
        static IntPtr handle = IntPtr.Zero;

        public static void Add(Process p)
        {
            if (handle == IntPtr.Zero)
            {
                handle = NativeMethods.CreateJobObject(IntPtr.Zero, null);
                var info = new NativeMethods.JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                info.BasicLimitInformation.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                int length = Marshal.SizeOf(typeof(NativeMethods.JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
                IntPtr ptr = Marshal.AllocHGlobal(length);
                try
                {
                    Marshal.StructureToPtr(info, ptr, false);
                    NativeMethods.SetInformationJobObject(handle, 9, ptr, (uint)length); // JobObjectExtendedLimitInformation
                }
                finally
                {
                    Marshal.FreeHGlobal(ptr);
                }
            }
            NativeMethods.AssignProcessToJobObject(handle, p.Handle);
        }
    }

    // ------------------------------------------------------------ proxy mode

    /// Points the per-user Windows (WinINet) proxy at the phone and puts the
    /// old values back afterwards. The old values are saved to disk first, so a
    /// crash or a closed window is repaired on the next run.
    static class SystemProxy
    {
        const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Internet Settings";
        static readonly string[] Names = { "ProxyEnable", "ProxyServer", "ProxyOverride" };

        static string BackupPath
        {
            get
            {
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "ModemBridge", "proxy-backup.txt");
            }
        }

        public static void Enable(string server)
        {
            using (var key = Registry.CurrentUser.OpenSubKey(KeyPath, true))
            {
                if (key == null) throw new Exception("Could not open the Windows Internet Settings registry key.");
                if (!File.Exists(BackupPath))
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(BackupPath));
                    File.WriteAllLines(BackupPath, Names.Select(n => Describe(key, n)).ToArray());
                }
                key.SetValue("ProxyEnable", 1, RegistryValueKind.DWord);
                key.SetValue("ProxyServer", server, RegistryValueKind.String);
                key.SetValue("ProxyOverride", "<local>;localhost;127.*", RegistryValueKind.String);
            }
            Refresh();
        }

        public static void RestoreFromBackup(bool verbose)
        {
            if (!File.Exists(BackupPath))
            {
                if (verbose) Log.Info("No saved proxy settings to restore.");
                return;
            }
            string[] lines = File.ReadAllLines(BackupPath);
            using (var key = Registry.CurrentUser.OpenSubKey(KeyPath, true))
            {
                if (key == null) return;
                foreach (var line in lines)
                {
                    var parts = line.Split(new[] { '|' }, 3);
                    if (parts.Length != 3 || !Names.Contains(parts[0])) continue;
                    if (parts[1] == "absent")
                    {
                        key.DeleteValue(parts[0], false);
                        continue;
                    }
                    RegistryValueKind kind;
                    if (!Enum.TryParse(parts[1], out kind)) continue;
                    object value;
                    if (kind == RegistryValueKind.DWord) value = int.Parse(parts[2], CultureInfo.InvariantCulture);
                    else if (kind == RegistryValueKind.QWord) value = long.Parse(parts[2], CultureInfo.InvariantCulture);
                    else value = parts[2];
                    key.SetValue(parts[0], value, kind);
                }
            }
            File.Delete(BackupPath);
            Refresh();
            Log.Info("Restored your previous Windows proxy settings.");
        }

        static string Describe(RegistryKey key, string name)
        {
            object value = key.GetValue(name);
            if (value == null) return name + "|absent|";
            return name + "|" + key.GetValueKind(name) + "|" + Convert.ToString(value, CultureInfo.InvariantCulture);
        }

        static void Refresh()
        {
            NativeMethods.InternetSetOption(IntPtr.Zero, 39, IntPtr.Zero, 0); // INTERNET_OPTION_SETTINGS_CHANGED
            NativeMethods.InternetSetOption(IntPtr.Zero, 37, IntPtr.Zero, 0); // INTERNET_OPTION_REFRESH
        }
    }

    // ------------------------------------------------------------- utilities

    static class Log
    {
        static readonly object gate = new object();
        static readonly Dictionary<string, DateTime> lastThrottled = new Dictionary<string, DateTime>();

        public static void Info(string message) { Write(message, ConsoleColor.Gray); }
        public static void Ok(string message) { Write(message, ConsoleColor.Green); }
        public static void Warn(string message) { Write(message, ConsoleColor.Yellow); }
        public static void Error(string message) { Write(message, ConsoleColor.Red); }

        /// Warns at most once every 10 seconds per key, so failures don't flood the window.
        public static void Throttled(string key, string message)
        {
            lock (gate)
            {
                DateTime last;
                if (lastThrottled.TryGetValue(key, out last) && (DateTime.UtcNow - last).TotalSeconds < 10) return;
                lastThrottled[key] = DateTime.UtcNow;
            }
            Warn(message);
        }

        static void Write(string message, ConsoleColor color)
        {
            lock (gate)
            {
                var previous = Console.ForegroundColor;
                Console.ForegroundColor = color;
                Console.WriteLine(DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture) + "  " + message);
                Console.ForegroundColor = previous;
            }
        }
    }

    static class Fmt
    {
        public static string Bytes(long count)
        {
            string[] units = { "B", "KB", "MB", "GB", "TB" };
            double value = count;
            int unit = 0;
            while (value >= 1024 && unit < units.Length - 1)
            {
                value /= 1024;
                unit++;
            }
            return value.ToString(unit == 0 ? "0" : "0.0", CultureInfo.InvariantCulture) + " " + units[unit];
        }
    }

    static class NativeMethods
    {
        public delegate bool ConsoleCtrlHandler(int ctrlType);

        [DllImport("kernel32.dll")]
        public static extern bool SetConsoleCtrlHandler(ConsoleCtrlHandler handler, bool add);

        [DllImport("wininet.dll", SetLastError = true)]
        public static extern bool InternetSetOption(IntPtr internet, int option, IntPtr buffer, int length);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr CreateJobObject(IntPtr attributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }
    }
}
