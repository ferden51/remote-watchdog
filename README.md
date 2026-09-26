# remote-watchdog

Uzaktaki bilgisayarı **server gibi** çalıştıran, bağlantı koparsa kendini onaran (gerekirse yeniden
başlatan) iki parçalı PowerShell watchdog projesi.

Bağlantı sorunlarının çoğu "makine açık ama erişilemiyor" şeklindedir ve iki ayrı katmanda çözülür:

1. **Yerinde (host)**: bağlantıyı bozan şeyi sıfırdan tespit edip onarır ve dışarıya "nabız" gönderir.
2. **Uzaktan (istemci)**: bağlantı gerçekten düşmüşse uyarır ve istemciyi otomatik açar.

## Klasör yapısı

| Dosya | Nerede çalışır | Görev |
|---|---|---|
| `host/RemoteHostWatchdog.ps1` | Uzak bilgisayar (SYSTEM) | CRD/RDP/uyku/saat/DNS testi, otomatik onarım, servis ayarları, heartbeat, Telegram uyarısı, gerekirse reboot |
| `host/Enable-ConsoleAutoLogon.ps1` | Uzak bilgisayar (admin) | Reboot sonrası konsola otomatik giriş (opt-in, riskli) |
| `client/RemoteClientWatchdog.ps1` | Kendi bilgisayarın | Uzak hedefe TCP erişim testi, kopma uyarısı, RDP/tarayıcı otomatik açma |

## Host tarafı ne yapar

- **Google Remote Desktop**: `chromoting` servisi durmuşsa başlatır, daemon takılmışsa temiz şekilde yeniden
  başlatır, servisi `Automatic` yapar ve çökerse Windows'un kendini yeniden başlatmasını sağlar
  (`sc.exe failure ... actions= restart/5000/restart/15000/restart/60000`).
  `host.json`/`host_id` yoksa bunu **otomatik çözemez** (cihaz Google listesinden düşer) — loglar ve uyarı
  gönderir, cihazın yeniden kaydedilmesi gerektiğini söyler.
- **Windows RDP**: `fDenyTSConnections`, `RemoteDesktop*` firewall kuralları (dil-bağımsız kural adlarıyla),
  `TermService`/`UmRdpService` durumu ve 3389 dinleme durumu.
- **Sunucu modu**: AC/DC uyku, hibernasyon ve disk zaman aşımlarını kapatır, **Fast Startup**'ı kapatır
  (`powercfg /h off`), ağ adaptörlerinin "cihazı kapatma" modunu kapatıp Wake-on-LAN'ı açar.
- **Saat senkronu**: sunucu saatine göre kayma 120 sn'yi aşarsa `w32tm /resync`.
- **Ağ**: DNS çözümlemesi ve `mtalk.google.com:443` (CRD sinyal yolu) kontrolü; takılı adaptörü yeniden başlatır.
- **Pil kontrolü**: dizüstü bilgisayarda pil bitmişse uyarır (sunucu modu için AC besleme şart).
- **Reboot politikası**: üst üste `RebootAfterFailedCycles` (varsayılan 3) başarısız döngü olursa ve sorun
  reboot ile düzeltilebilecek türdense makineyi yeniden başlatır. `host.json` kayıp ise **reboot yapmaz**
  (işe yaramaz), makine yeni açıldıysa eşiğe ulaşmadan beklemez (`MinUptimeMinutes`).

## Kurulum — uzak bilgisayar (fiziksel erişim gerekir)

```powershell
irm https://raw.githubusercontent.com/ferden51/remote-watchdog/main/host/RemoteHostWatchdog.ps1 -OutFile "$env:TEMP\RemoteHostWatchdog.ps1"

# once rapor al (hicbir sey degistirmez)
powershell -ExecutionPolicy Bypass -File "$env:TEMP\RemoteHostWatchdog.ps1" -Check

# sonra kur (admin, kendini yeniden baslatir)
powershell -ExecutionPolicy Bypass -File "$env:TEMP\RemoteHostWatchdog.ps1" -Install -IntervalMinutes 5 `
  -TelegramToken '123456:ABC' -TelegramChatId '987654'
```

Repo **private** olduğu için indirme için GitHub kimlik doğrulaması gerekir (`gh`, PAT veya USB/OneDrive).

Kurulumdan sonra: `Get-ScheduledTask RemoteHostWatchdog`, log: `C:\ProgramData\RemoteWatchdog\host-watchdog.log`,
config: `C:\ProgramData\RemoteWatchdog\config.json`.

## Kurulum — kendi bilgisayarın (istemci, admin gerektirmez)

```powershell
irm https://raw.githubusercontent.com/ferden51/remote-watchdog/main/client/RemoteClientWatchdog.ps1 -OutFile "$env:TEMP\RemoteClientWatchdog.ps1"

powershell -ExecutionPolicy Bypass -File "$env:TEMP\RemoteClientWatchdog.ps1" -Install -IntervalMinutes 10 `
  -Target '100.64.1.5:3389' -RdpFile 'C:\rdp\finrex.rdp' -TelegramToken '123456:ABC' -TelegramChatId '987654'
```

`-Target` verilmezse yalnızca Google/CRD sinyal yolu kontrol edilir. RDP yerel dosyası verilirse
bağlantı düzeldiğinde `mstsc` otomatik açılır.

## Dışarıdan "hâlâ çalışıyor mu" sinyali

- **Telegram**: durum değişince tek mesaj, sorun sürerse `AlertRepeatHours` saatte bir tekrar.
- **healthchecks.io**: `https://hc-ping.com/<uuid>` adresini `-HeartbeatUrl` ile verirseniz sunucu
  dönüp durması / hata vermesi durumunda e-posta veya çağrı gelir. Sorun halinde `<uuid>/fail` adresine gider.
  Yeni bir check oluşturup `Period: 5m`, `Grace: 10m` seçin (dead-man's switch).
- **GitHub Actions** alternatifi: repo içine `schedule` ile çalışan, healthchecks.io ping atan bir iş akışı
  konabilir; böylece host'un haber vermesi hiç olmazsa bile alarm çalar.

## İnsanın yapması gerekenler (watchdog çözemez)

- **BIOS**: *Restore on AC Power Loss = Power On* ve *Wake on LAN = Enabled*. Elektrik gidip geldiğinde
  makine kendiliğinden açılmazsa hiçbir yazılım işe yaramaz.
- **Google CRD yeniden kayıt**: `host.json` silinmişse cihaz listeden kaybolur. Makinede
  `https://remotedesktop.google.com/headless` → *Set up remote access* → PIN al, kendi cihazında
  *Machines → +* ile ad + PIN gir.
- **RDP portu**: Windows RDP'ye internetten erişmek için yönlendirme/VPN gerekir (Tailscale önerilir);
  firewall kuralını açmak tek başına dışarıya port açmaz.
- **Güncellemeler**: Windows Update'ün çalışma saatinde yeniden başlatmasını istemiyorsan
  `active hours` veya `MaintenanceWindow` ayarla.
- **Otomatik giriş** (opsiyonel): `host/Enable-ConsoleAutoLogon.ps1` reboot sonrası konsola kendiliğinden
  girer; parolayı registry'de düz metin saklar, sadece güvenli ağlarda kullan.

## Yapılandırma (`config.json`)

| Anahtar | Varsayılan | Açıklama |
|---|---|---|
| `IntervalMinutes` | 5 | Kontrol aralığı (zamanlanmış görev) |
| `ServerMode` | true | Uyku/hibernasyon/NIC gücünü kapat |
| `RebootAfterFailedCycles` | 3 | Kaç başarısız döngüden sonra reboot, `0` = hiç |
| `RebootSkipIfUnregistered` | true | `host.json` yoksa reboot etme |
| `MinUptimeMinutes` | 30 | Yeni açılan makineyi hemen reboot etme |
| `CrdRestartAfterHours` | 0 | >0 ise bağlantı yokken bu yaştan sonra CRD'yi önleyici yeniden başlat |
| `AlertRepeatHours` | 12 | Aynı sorun için tekrar uyarı aralığı |
| `ServiceCrashRecovery` | true | Servis çökerse Windows kendini yeniden başlatsın |

## Testler

`host/RemoteHostWatchdog.ps1 -Check` ve `client/RemoteClientWatchdog.ps1 -Check` hiçbir sistem değişikliği
yapmadan tüm kontrolleri çalıştırır; `-Status` son logları ve sayaçları gösterir.
