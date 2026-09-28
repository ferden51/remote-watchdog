// RemoteWatchdog ses paketi - "uzay filmi" tarzi arayuz efektleri (saf .NET, harici bagimlilik yok).
// Cikti: 16-bit PCM WAV, 44.1 kHz stereo. Uretici: tools/New-SoundPack.ps1
//
// Tasarim ilkeleri (istenen his: net, keskin, parlak, gercekci):
//   * Attack < 2 ms + 2 ms parlak transient (click)  -> "cis" gibi net keskinlik
//   * Inharmonik can kisimlari (1 / 2 / 2.76 / 5.40 / 8.93) -> metalik uzay istasyonu tini
//   * HP'li shimmer'li kisa reverb                   -> genis, temiz, uzay filmi kuyrugu
//   * Sub katman (55-330 Hz)                         -> laptop hoparlorunde de guc hissi
//   * tanh soft limiter                              -> kirpmasiz, temiz tepe (netlik)
using System;
using System.IO;
using System.Text;

public class SfxPack
{
    public const int SR = 44100;
    private static Random Rng = new Random(20260928);

    public static string[] Names = new string[] { "online", "ok", "warn", "alert", "repair", "recover", "reboot", "scan" };

    public class Mix
    {
        public int N;
        public double[] L;
        public double[] R;

        public Mix(double seconds)
        {
            int n = (int)Math.Ceiling(seconds * SR);
            if (n < 256) { n = 256; }
            N = n;
            L = new double[n];
            R = new double[n];
        }

        public void Add(int i, double v, double panL, double panR)
        {
            if (i < 0) { return; }
            if (i < N) { L[i] += v * panL; R[i] += v * panR; }
            int j = i + 1;
            if (j < N) { L[j] += v * 0.5 * panL; R[j] += v * 0.5 * panR; }
        }
    }

    private static double PanL(double pan) { return Math.Sqrt(0.5 * (1.0 - pan)); }
    private static double PanR(double pan) { return Math.Sqrt(0.5 * (1.0 + pan)); }

    private static double TailWindow(int n, int len)
    {
        int tail = (int)(0.030 * SR);
        if (tail < 8) { tail = 8; }
        if (n <= len - tail) { return 1.0; }
        double w = (double)(len - n) / tail;
        return w < 0.0 ? 0.0 : w;
    }

    // --- Bell / cam ping: inharmonik kisimlar, 1.5 ms attack (keskin), ayarlanabilir parlaklik ---
    public static void Bell(Mix m, double t0, double dur, double f0, double amp, double decay, double bright, double pan, bool glassy)
    {
        int start = (int)(t0 * SR);
        int len = (int)(dur * SR);
        if (len < 16) { return; }
        double[] ratios = glassy ? new double[] { 1.0, 2.01, 3.02, 4.06, 6.11 } : new double[] { 1.0, 2.0, 2.76, 5.40, 8.93 };
        double[] pa = new double[ratios.Length];
        double sum = 0.0;
        for (int i = 0; i < ratios.Length; i++)
        {
            pa[i] = Math.Pow(bright, i) / (1.0 + 0.6 * i);
            sum += pa[i];
        }
        int atk = (int)(0.0015 * SR);
        if (atk < 2) { atk = 2; }
        double pl = PanL(pan);
        double pr = PanR(pan);
        for (int n = 0; n < len; n++)
        {
            double t = (double)n / SR;
            double env = n < atk ? (double)n / atk : 1.0;
            double v = 0.0;
            for (int i = 0; i < ratios.Length; i++)
            {
                double d = decay / (1.0 + 0.32 * i);
                double det = 1.0 + 0.0012 * i * ((i % 2 == 0) ? 1.0 : -1.0);
                v += pa[i] * Math.Exp(-t / d) * Math.Sin(2.0 * Math.PI * f0 * ratios[i] * det * t + i * 0.7);
            }
            v = v / sum * amp * env * TailWindow(n, len);
            m.Add(start + n, v, pl, pr);
        }
    }

    // --- Tone / sweep: harmonik zengin (harm=1 saf sinus, 6 = testere gibi parlak) ---
    public static void Tone(Mix m, double t0, double dur, double f0, double f1, double amp, double pan, int harm, double attackSec, double decaySec)
    {
        int start = (int)(t0 * SR);
        int len = (int)(dur * SR);
        if (len < 16) { return; }
        int atk = (int)(attackSec * SR);
        if (atk < 2) { atk = 2; }
        if (harm < 1) { harm = 1; }
        double pl = PanL(pan);
        double pr = PanR(pan);
        double[] phase = new double[harm];
        for (int n = 0; n < len; n++)
        {
            double t = (double)n / SR;
            double u = (double)n / len;
            double f = f0 * Math.Pow(f1 / f0, u);
            double v = 0.0;
            for (int h = 0; h < harm; h++)
            {
                int k = h + 1;
                phase[h] += 2.0 * Math.PI * f * k / SR;
                v += Math.Sin(phase[h]) / k;
            }
            double env = n < atk ? (double)n / atk : Math.Exp(-(t - attackSec) / decaySec);
            m.Add(start + n, v * amp * env * TailWindow(n, len), pl, pr);
        }
    }

    // --- Noise: HP/LP filtreli, cutoff'u kayabilen gurultu (whoosh / shimmer) ---
    public static void Noise(Mix m, double t0, double dur, double amp, double hp, double lpFrom, double lpTo, double pan, double shape)
    {
        int start = (int)(t0 * SR);
        int len = (int)(dur * SR);
        if (len < 16) { return; }
        int atk = (int)(0.003 * SR);
        if (atk < 2) { atk = 2; }
        double pl = PanL(pan);
        double pr = PanR(pan);
        double zl = 0.0;
        double zr = 0.0;
        double hl = 0.0;
        double hr = 0.0;
        double ahp = 1.0 - Math.Exp(-2.0 * Math.PI * hp / SR);
        for (int n = 0; n < len; n++)
        {
            double u = (double)n / len;
            double fc = lpFrom * Math.Pow(lpTo / lpFrom, u);
            double a = 1.0 - Math.Exp(-2.0 * Math.PI * fc / SR);
            double xl = Rng.NextDouble() * 2.0 - 1.0;
            double xr = Rng.NextDouble() * 2.0 - 1.0;
            zl += (xl - zl) * a;
            zr += (xr - zr) * a;
            hl += (zl - hl) * ahp;
            hr += (zr - hr) * ahp;
            double env = n < atk ? (double)n / atk : Math.Pow(Math.Sin(Math.PI * u), shape);
            m.Add(start + n, (zl - hl) * amp * env * TailWindow(n, len), pl, pr);
            m.Add(start + n, (zr - hr) * amp * env * TailWindow(n, len), pl, pr);
        }
    }

    // --- Click: 4 ms parlak transient ("cis" hissi, sesleri netlestirir) ---
    public static void Click(Mix m, double t0, double amp, double pan)
    {
        int start = (int)(t0 * SR);
        int len = (int)(0.004 * SR);
        if (len < 4) { len = 4; }
        double pl = PanL(pan);
        double pr = PanR(pan);
        double z = 0.0;
        for (int n = 0; n < len; n++)
        {
            double u = (double)n / len;
            double x = Rng.NextDouble() * 2.0 - 1.0;
            z += (x - z) * 0.35;
            m.Add(start + n, (x - z) * amp * Math.Exp(-u * 6.0), pl, pr);
        }
    }

    // --- Sub: alcak frekansli guc katmani (hoparlorsuz laptopta bile hissedilir) ---
    public static void Sub(Mix m, double t0, double dur, double f0, double f1, double amp, double pan)
    {
        int start = (int)(t0 * SR);
        int len = (int)(dur * SR);
        if (len < 16) { return; }
        int atk = (int)(0.008 * SR);
        if (atk < 2) { atk = 2; }
        double pl = PanL(pan * 0.3);
        double pr = PanR(pan * 0.3);
        double phase = 0.0;
        for (int n = 0; n < len; n++)
        {
            double u = (double)n / len;
            double f = f0 * Math.Pow(f1 / f0, u);
            phase += 2.0 * Math.PI * f / SR;
            double env = n < atk ? (double)n / atk : Math.Exp(-((double)n / SR - 0.008) / (dur * 0.55));
            double v = (Math.Sin(phase) + 0.15 * Math.Sin(3.0 * phase)) * amp * env * TailWindow(n, len);
            m.Add(start + n, v, pl, pr);
        }
    }

    // --- Reverb: 5 tarafli, damped geri besleme + HP shimmer (genis ve parlak kuyruk) ---
    public static void Reverb(Mix m, double amount, double sizeSec, double damp)
    {
        int n = m.N;
        double[] dryL = (double[])m.L.Clone();
        double[] dryR = (double[])m.R.Clone();
        double[] wetL = new double[n];
        double[] wetR = new double[n];
        double[] taps = new double[] { 0.0083, 0.0149, 0.0247, 0.0409, 0.0631 };
        double[] gains = new double[] { 0.60, 0.54, 0.47, 0.41, 0.35 };
        double a = 1.0 - Math.Exp(-2.0 * Math.PI * damp / SR);
        for (int i = 0; i < taps.Length; i++)
        {
            int d = (int)(taps[i] * sizeSec * SR);
            if (d < 8) { d = 8; }
            double sign = (i % 2 == 0) ? 1.0 : -1.0;
            double fb = gains[i] * amount;
            double pan = (i - 2.0) * 0.14;
            double pl = PanL(pan);
            double pr = PanR(pan);
            double z = 0.0;
            for (int k = d; k < n; k++)
            {
                double x = dryL[k - d] * 0.6 + dryR[k - d] * 0.4;
                z = x * sign * fb + z * (1.0 - a);
                wetL[k] += z * pl;
                wetR[k] += z * pr;
            }
        }
        double prevL = 0.0;
        double prevR = 0.0;
        for (int k = 0; k < n; k++)
        {
            double hpL = wetL[k] - prevL;
            double hpR = wetR[k] - prevR;
            prevL = wetL[k];
            prevR = wetR[k];
            m.L[k] += wetL[k] * 0.55 + hpL * 0.45;
            m.R[k] += wetR[k] * 0.55 + hpR * 0.45;
        }
    }

    // --- Bitir: normalize + soft limiter + kenar fade (bas/son tik sesi olmaz) ---
    public static void Finish(Mix m, double peak, double drive, double fadeMs)
    {
        double p = 0.0;
        for (int i = 0; i < m.N; i++)
        {
            double a = Math.Abs(m.L[i]);
            if (a > p) { p = a; }
            a = Math.Abs(m.R[i]);
            if (a > p) { p = a; }
        }
        double g = p > 1e-9 ? peak / p : 1.0;
        double k = Math.Tanh(drive);
        for (int i = 0; i < m.N; i++)
        {
            m.L[i] = Math.Tanh(m.L[i] * g * drive) / k;
            m.R[i] = Math.Tanh(m.R[i] * g * drive) / k;
        }
        int f = (int)(fadeMs * SR / 1000.0);
        if (f < 8) { f = 8; }
        for (int i = 0; i < f && i < m.N; i++)
        {
            double w = (double)i / f;
            m.L[i] *= w;
            m.R[i] *= w;
            m.L[m.N - 1 - i] *= w;
            m.R[m.N - 1 - i] *= w;
        }
    }

    private static short ToPcm(double v)
    {
        double x = v * 32767.0;
        if (x > 32767.0) { x = 32767.0; }
        if (x < -32768.0) { x = -32768.0; }
        return (short)Math.Round(x);
    }

    // 44 baytlik standart PCM WAV basligi + veri (16-bit, stereo, 44.1 kHz)
    public static void Save(string path, Mix m)
    {
        int dataBytes = m.N * 4;
        using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write))
        {
            BinaryWriter w = new BinaryWriter(fs);
            w.Write(Encoding.ASCII.GetBytes("RIFF"));
            w.Write(36 + dataBytes);
            w.Write(Encoding.ASCII.GetBytes("WAVE"));
            w.Write(Encoding.ASCII.GetBytes("fmt "));
            w.Write(16);
            w.Write((short)1);
            w.Write((short)2);
            w.Write(SR);
            w.Write(SR * 4);
            w.Write((short)4);
            w.Write((short)16);
            w.Write(Encoding.ASCII.GetBytes("data"));
            w.Write(dataBytes);
            for (int i = 0; i < m.N; i++)
            {
                w.Write(ToPcm(m.L[i]));
                w.Write(ToPcm(m.R[i]));
            }
            w.Flush();
        }
    }

    // --- 1) ok: DOGRULAMA / islem tamamlandi - parlak tek ping, kisa kuyruk ---
    public static Mix BuildOk()
    {
        Mix m = new Mix(0.62);
        Click(m, 0.000, 0.16, -0.05);
        Bell(m, 0.000, 0.58, 1318.5, 0.85, 0.26, 0.72, -0.10, false);
        Bell(m, 0.010, 0.46, 1975.5, 0.30, 0.15, 0.80, 0.12, true);
        Sub(m, 0.000, 0.30, 330.0, 300.0, 0.10, 0.0);
        Noise(m, 0.000, 0.30, 0.05, 6000.0, 9000.0, 9000.0, 0.18, 1.6);
        Reverb(m, 0.30, 0.55, 6500.0);
        Finish(m, 0.90, 1.15, 2.0);
        return m;
    }

    // --- 2) warn: UYARI - iki notali, hafif detune (gerilim), keskin cikisli ---
    public static Mix BuildWarn()
    {
        Mix m = new Mix(0.85);
        Click(m, 0.000, 0.14, -0.06);
        Click(m, 0.200, 0.12, 0.06);
        Bell(m, 0.000, 0.42, 1244.5, 0.78, 0.20, 0.74, -0.14, false);
        Bell(m, 0.000, 0.42, 1257.0, 0.26, 0.18, 0.78, -0.12, false);
        Bell(m, 0.195, 0.60, 932.3, 0.82, 0.26, 0.78, 0.14, false);
        Bell(m, 0.195, 0.60, 941.5, 0.28, 0.24, 0.82, 0.16, false);
        Noise(m, 0.170, 0.34, 0.10, 2400.0, 4000.0, 7000.0, 0.10, 1.3);
        Sub(m, 0.000, 0.32, 233.1, 186.5, 0.14, 0.0);
        Reverb(m, 0.34, 0.62, 6000.0);
        Finish(m, 0.92, 1.15, 2.0);
        return m;
    }

    // --- 3) alert: KRITIK ALARM - 3 darbeli klakson, metalik kenar, sub baski ---
    public static Mix BuildAlert()
    {
        Mix m = new Mix(1.32);
        for (int i = 0; i < 3; i++)
        {
            double t = i * 0.42;
            Click(m, t, 0.20, 0.0);
            Tone(m, t, 0.34, 622.25, 523.25, 0.72, 0.0, 6, 0.005, 0.30);
            Tone(m, t, 0.34, 1244.5, 1046.5, 0.24, 0.0, 4, 0.005, 0.26);
            Bell(m, t, 0.12, 1864.7, 0.26, 0.06, 0.90, -0.10, true);
        }
        Noise(m, 0.000, 1.24, 0.09, 6000.0, 8000.0, 10000.0, 0.0, 0.9);
        Sub(m, 0.000, 1.24, 130.8, 116.5, 0.22, 0.0);
        Reverb(m, 0.24, 0.40, 7000.0);
        Finish(m, 0.95, 1.30, 2.0);
        return m;
    }

    // --- 4) repair: ONARIM SURUYOR - sonar taramasi (yukselen, tekrarlanabilir ping) ---
    public static Mix BuildRepair()
    {
        Mix m = new Mix(1.12);
        for (int i = 0; i < 3; i++)
        {
            double t = i * 0.33;
            double amp = 0.72 - i * 0.12;
            double pan = -0.08 + i * 0.08;
            Click(m, t, 0.14, pan);
            Bell(m, t, 0.30, 1568.0, amp, 0.15, 0.80, pan, true);
            Tone(m, t, 0.16, 700.0, 1500.0, 0.12, pan, 3, 0.006, 0.10);
        }
        Sub(m, 0.000, 0.60, 250.0, 200.0, 0.10, 0.0);
        Noise(m, 0.000, 0.95, 0.06, 3000.0, 5000.0, 9000.0, 0.0, 0.8);
        Reverb(m, 0.34, 0.50, 7000.0);
        Finish(m, 0.92, 1.15, 2.0);
        return m;
    }

    // --- 5) recover: BAGLANTI DUZELDI - yukselen shimmer + parlak cift cingi ---
    public static Mix BuildRecover()
    {
        Mix m = new Mix(1.15);
        Noise(m, 0.000, 0.42, 0.10, 2500.0, 3000.0, 9000.0, 0.0, 1.4);
        Tone(m, 0.000, 0.42, 320.0, 2600.0, 0.40, -0.05, 5, 0.010, 0.40);
        Sub(m, 0.000, 0.50, 160.0, 220.0, 0.12, 0.0);
        Bell(m, 0.400, 0.62, 1568.0, 0.72, 0.30, 0.85, -0.06, true);
        Bell(m, 0.560, 0.58, 2093.0, 0.58, 0.28, 0.85, 0.08, true);
        Reverb(m, 0.40, 0.80, 6800.0);
        Finish(m, 0.92, 1.15, 2.0);
        return m;
    }

    // --- 6) reboot: SISTEM YENIDEN BASLATILIYOR - alcalan supurme + sub + net blip ---
    public static Mix BuildReboot()
    {
        Mix m = new Mix(1.28);
        Click(m, 0.000, 0.22, 0.0);
        Bell(m, 0.000, 0.26, 2349.3, 0.24, 0.12, 0.88, 0.06, true);
        Noise(m, 0.000, 0.95, 0.16, 1200.0, 1200.0, 400.0, 0.0, 1.1);
        Tone(m, 0.000, 0.95, 1500.0, 130.0, 0.50, 0.0, 4, 0.008, 0.90);
        Sub(m, 0.030, 1.00, 130.0, 55.0, 0.42, 0.0);
        Reverb(m, 0.30, 0.70, 5500.0);
        Finish(m, 0.95, 1.25, 2.0);
        return m;
    }

    // --- 7) online: SISTEM CEVRIMICI - iki notali cam can + uzun parlak kuyruk ---
    public static Mix BuildOnline()
    {
        Mix m = new Mix(1.50);
        Click(m, 0.000, 0.18, 0.0);
        Bell(m, 0.000, 1.25, 1046.5, 0.55, 0.55, 0.68, -0.12, false);
        Bell(m, 0.150, 1.20, 1568.0, 0.60, 0.55, 0.76, 0.12, false);
        Sub(m, 0.000, 0.70, 131.0, 131.0, 0.16, 0.0);
        Noise(m, 0.020, 1.10, 0.05, 6000.0, 8000.0, 9000.0, 0.0, 0.7);
        Reverb(m, 0.44, 1.00, 6500.0);
        Finish(m, 0.92, 1.12, 2.5);
        return m;
    }

    // --- 8) scan: KONTROL BASLADI - iki mikro blip (arayuz tiki, keskin ve kisa) ---
    public static Mix BuildScan()
    {
        Mix m = new Mix(0.50);
        Click(m, 0.000, 0.13, -0.05);
        Click(m, 0.120, 0.11, 0.05);
        Bell(m, 0.000, 0.20, 2093.0, 0.55, 0.07, 0.82, -0.06, true);
        Bell(m, 0.120, 0.24, 2637.0, 0.50, 0.09, 0.84, 0.06, true);
        Noise(m, 0.000, 0.30, 0.04, 6000.0, 9000.0, 9000.0, 0.0, 0.9);
        Reverb(m, 0.26, 0.28, 7500.0);
        Finish(m, 0.85, 1.10, 1.5);
        return m;
    }

    // Tek efekti uret (adiyla); sureyi saniye olarak doner
    public static double Build(string dir, string name)
    {
        Mix m = null;
        switch (name)
        {
            case "online": m = BuildOnline(); break;
            case "ok": m = BuildOk(); break;
            case "warn": m = BuildWarn(); break;
            case "alert": m = BuildAlert(); break;
            case "repair": m = BuildRepair(); break;
            case "recover": m = BuildRecover(); break;
            case "reboot": m = BuildReboot(); break;
            case "scan": m = BuildScan(); break;
            default: throw new ArgumentException("bilinmeyen efekt: " + name);
        }
        Save(Path.Combine(dir, name + ".wav"), m);
        return (double)m.N / SR;
    }

    public static int BuildAll(string dir)
    {
        if (!Directory.Exists(dir)) { Directory.CreateDirectory(dir); }
        for (int i = 0; i < Names.Length; i++)
        {
            Build(dir, Names[i]);
        }
        return Names.Length;
    }
}
