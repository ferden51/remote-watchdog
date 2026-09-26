# remote-watchdog

Uzaktaki bilgisayarı **server gibi** çalıştıran, bağlantı koparsa kendini onaran (gerekirse yeniden
başlatan) iki parçalı PowerShell watchdog projesi.

Bağlantı sorunlarının çoğu "makine açık ama erişilemiyor" şeklindedir ve iki ayrı katmanda çözülür:

1. **Yerinde (host)**: bağlantıyı bozan şeyi sıfırdan tespit edip onarır ve dışarıya "nabız" gönderir.
2. **Uzaktan (istemci)**: bağlantı gerçekten düşmüşse uyarır ve istemciyi otomatik açar.

## Klasör yapısı

| Dosya | Nerede çalışır | Görev |
|---|---|---|
| `host/RemoteHostWatchdog.ps1` | Uzak bilgisayar (SYSTEM) | CRD/RDP/uyku/saat/ağ testi, kademeli ağ onarımı, otomatik servis ayarları, heartbeat, Telegram uyarısı, gerekirse reboot |
| `host/Protect-OpenDocuments.ps1` | Uzak bilgisayar (kullanıcı oturumu) | Kaydedilmemiş Word/Excel belgelerini periyodik kaydeder, AutoRecover'ı kısaltır, reboot öncesi kaydedip kapatır |
| `host/Collect-Diagnostics.ps1` | Uzak bilgisayar | 14 günlük olay günlüğü + ağ/DHCP/uyku analizi, puanlı şüpheli listesi (hiçbir şeyi değiştirmez) |
| `host/Enable-ConsoleAutoLogon.ps1` | Uzak bilgisayar (admin) | Reboot sonrası konsola otomatik giriş (opt-in, riskli) |
| `client/RemoteClientWatchdog.ps1` | Kendi bilgisayarın | Uzak hedefe TCP erişim testi, kopma uyarısı, RDP/tarayıcı otomatik açma |
| `ui/RemoteWatchdogPanel.ps1` | Her iki makinede (kullanıcı oturumu) | Sistem tepsisi kontrol paneli: durum, bekleyen işler, tüm ayarlar, daima zorla kapatma anahtarı, loglar, teşhis raporu |

## Kurulum: iki modül

| Modül | Nerede kurulur | Ne yapar | Admin |
|---|---|---|---|
| **host** | Uzak bilgisayar (fiziksel erişim gerekir) | CRD/RDP/ağ/uyku testi, kademeli onarım, servis ayarları, alarm, gerekirse restart, belge koruma | Gerekli |
| **client** | Senin bilgisayarın | Uzak makineye TCP erişim testi, kopma alarmı, RDP/tarayıcı otomatik açma | Gerekmez |
| **tray** | İkisi de | Yukarıdakilerin durumunu ve ayarlarını gösteren panel | Gerekmez |

Klasörün **tamamını** hedef makineye kopyala (veya `git clone`), sonra:

### Uzak bilgisayar (host)

```powershell
powershell -ExecutionPolicy Bypass -File .\install\Install-Host.ps1 -TelegramToken '123:ABC' -TelegramChatId '456'
```

Sırasıyla: teşhis raporu üretir (okuma modunda) → watchdog + belge koruyucu görevlerini kurar → tray'i
oturum açılışında başlatır → **en sonda CRD'yi `https://remotedesktop.google.com/headless` ile yeniden
kaydetmeni söyler** (bu adım watchdog ile yapılamaz). Admin değilsen script kendini yönetici olarak
yeniden başlatır. `-DryRun` ile önce ne yapacağını görebilirsin, `-KeepSleep` dizüstü profili,
`-SkipTray` tray'i atlar.

### Kendi bilgisayarın (client)

```powershell
powershell -ExecutionPolicy Bypass -File .\install\Install-Client.ps1 -Target '100.64.1.5:3389' -RdpFile 'C:\rdp\finrex.rdp' -TelegramToken '123:ABC' -TelegramChatId '456'
```

`-Target` uzak makinenin **o makineden erişilebilir bir adresi** olmalı (Tailscale IP'si gibi; internetteki
genel IP'ye port yönlendirme yoksa o IP'ye bağlanılamaz). `-Target` verilmezse yalnızca Google/CRD sinyal
yolu test edilir.

Repo private olduğu için `irm` ile tek satır indirme yetki ister; USB/OneDrive ile kopyalamak veya
`git clone` en pratik yol.



`ui/RemoteWatchdogPanel.ps1` tek dosyalık bir WinForms uygulamasıdır; klavye/fare gerektirmez.

```powershell
.\RemoteWatchdogPanel.ps1                 # tray'de başlar (simgeye çift tıkla = panel)
.\RemoteWatchdogPanel.ps1 -Install        # oturum açılışında otomatik başlat
.\RemoteWatchdogPanel.ps1 -SelfTest       # arayüzü kurup doldurup kapatır (test için)
```

Tepsisindeki simge **duruma göre renklenir**: yeşil (ayakta), kırmızı (sorun), gri (veri yok). Simgeye tıkla,
sağ tıkla: *Şimdi denetle*, *Kontrol panelini aç*, *Sessiz mod*, *Log klasörünü aç*, *Google Remote Desktop*,
*Watchdog kur*, *Teşhis raporu üret*, *Tray'den kapat*. Çift tıklama paneli açar. Tek kopya çalışır (mutex).

Panelde dört sekme:

**1. Durum** — sistem ayakta mı, uzak makinenin her kontrolünün sonucu, bu makinenin (istemci) kontrolü,
son denetim zamanı, uptime, kamu IP, görev durumu, blackout/tatil durumu, arıza sayacı, ağ onarım kademesi.

**2. Bekleyen işler** — yapılması gerekenler listelenir ve tek tıkla çözülür: görev kurulu değil, watchdog
dönmüyor, `host_id=YOK` (CRD yeniden kayıt), ağ onarımı, kaydedilmemiş belge (kaydet), winsock reset sonrası
restart. Ayrıca **"Şimdi zorla kapat ve yeniden başlat"** düğmesi: `ForceRestartAlways` anahtarını açar ve
restart ister (belgeler önce kaydedilir).

**3. Ayarlar** — kontrol aralığı, restart politikası (`blackout` / `always` / `never`), blackout başlangıç/bitiş
saati, tam gün blackout günleri, tatil modu ve tatil listesi, **daima zorla kapatma (isteğe bağlı bitiş zamanıyla)**,
restart koşulları (başarısız deneme sayısı, gecikme, minimum uptime, ağ kademesi), sunucu modu / Fast Startup,
belge koruma anahtarları, Telegram token/chat id, alarm tekrar aralığı, healthchecks adresi, istemci hedefleri.
Kaydet dediğinde `config.json` güncellenir, bir sonraki denetimde geçerli olur.

**4. Günlük** — host ve istemci loglarının son 120 satırı; *Yenile*, *Log dosyasını aç*, *Tümünü kopyala*,
*Teşhis raporu üret*.


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

### Profil seçimi: masaüstü (sürekli açık) vs dizüstü

Varsayılan **sunucu modu**: uyku, hibernasyon, disk zaman aşımı kapatılır, Fast Startup kapanır, ağ adaptörü
uykuya girmez. Bu, dışarıdan erişilecek makine için doğru olan ayardır.

Dizüstü olarak kullanılacak, uyuması gereken bir makineye kuruyorsan değişiklik yapılmasın:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:TEMP\RW.ps1" -Install -KeepSleep
```

`-KeepSleep` yalnızca `ServerMode`, `DisableHibernation` ve `DisableFastStartup` değerlerini kapatır; CRD
servisi, RDP, saat senkronu, ağ ve alarm tarafı yine kurulur. Kural: **bir kişinin önünde açık duran ve
uzaktan kullanılan makine** → varsayılan; **taşınabilir, günlük kullanılan makine** → `-KeepSleep`.

## Kurulum — kendi bilgisayarın (istemci, admin gerektirmez)

```powershell
irm https://raw.githubusercontent.com/ferden51/remote-watchdog/main/client/RemoteClientWatchdog.ps1 -OutFile "$env:TEMP\RemoteClientWatchdog.ps1"

powershell -ExecutionPolicy Bypass -File "$env:TEMP\RemoteClientWatchdog.ps1" -Install -IntervalMinutes 10 `
  -Target '100.64.1.5:3389' -RdpFile 'C:\rdp\finrex.rdp' -TelegramToken '123456:ABC' -TelegramChatId '987654'
```

`-Target` verilmezse yalnızca Google/CRD sinyal yolu kontrol edilir. RDP yerel dosyası verilirse
bağlantı düzeldiğinde `mstsc` otomatik açılır.

## Veri kaybına karşı koruma

`host/Protect-OpenDocuments.ps1` kullanıcı oturumunda **her 2 dakikada bir** çalışır (kurulumla birlikte
`RemoteHostOfficeSaver` görevi olarak kaydedilir):

- Word `Options.SaveInterval` ve Excel `AutoRecoverInterval` değerlerini 3 dakikaya çeker → AutoRecover
  dosyaları sık yazılır, beklenmedik kapanmada geri dönülebilir.
- **Kaydedilmemiş ve dosya yolu olan** her Word/Excel belgesini diske kaydeder. Yeni/adlı belge
  (`Save As` gerektiren), salt okunur veya başkasıyla paylaşılan belgeleri kaydetmeye çalışmaz; onları
  raporlar ve uyarı üretir (botomatik `Save As` penceresi açıp makineyi kilitlemesin diye).
- Durumu `C:\Windows\Temp\RemoteWatchdog-docs.json` dosyasına yazar; watchdog reboot kararı vermeden önce
  burayı okur: **kaydedilmemiş belge varsa reboot yapılmaz**, Telegram'dan uyarılır.
- Reboot zaten kaçınılmazsa önce istek dosyasını yazar, belge koruyucu belgeleri kaydedip Word/Excel'i
  kapatır; yine de kapanmazsa (`Save As` penceresi açık kalmış olabilir) reboot **iptal edilir** —
  `OfficeAbortRebootIfStillOpen` ve `OfficeAbortRebootIfUnsaved` ile kapatılabilir.

Elle kontrol: `.\Protect-OpenDocuments.ps1 -Status` → açık olan uygulamalar, kaydedilmemiş belge sayısı ve
koruyucunun neden kaydedemediği belgeler.

VS Code tarafında ek bir güvence zaten var: **Hot Exit** kirli sekmeleri diske yazdığı için yeniden
başlatmadan sonra sekmeler geri gelir.

## Dışarıdan "hâlâ çalışıyor mu" sinyali

- **Telegram**: durum değişince tek mesaj, sorun sürerse `AlertRepeatHours` saatte bir tekrar. Bot token `config.json` içinde **düz metin** saklanır; `Install-Host` klasör ACL'ini (SYSTEM + Administrators + kullanıcı) sıkılaştırır, istemci tarafında dosya kullanıcı profilinde kalır.
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
| `BlackoutEnabled` | true | Blackout penceresini kullan (kapali ise her saat korumali davranis) |
| `BlackoutStart` / `BlackoutEnd` | 18 / 8 | Blackout saati; bitis < baslangic ise geceye sarar |
| `BlackoutFullDays` | `[Cmt, Paz]` | Cumartesi ve Pazar tam gun zorla kapatma + restart |
| `BlackoutNights` | `[Pzt..Paz]` | Hangi gecelerde blackout gecerli |
| `RestartPolicy` | blackout | `blackout` = sadece blackout saatlerinde restart, `always` = her kosulda, `never` = hic |
| `ForceRestartAlways` / `ForceRestartUntil` | false / bos | Saat fark etmeksizin zorla kapatma; bitis zamani verilebilir |
| `HolidayMode` | full | `full` = tatil tam blackout, `default` = normal kural, `none` = yok say |
| `Holidays` | bos | Tatil listesi, her satir `YYYY-AA-GG` |
| `NotifyRepeatHours` | 4 | Kullanici bilgilendirme tekrar araligi (ekran/Telegram uyarisi) |
| `OfficeAbortRebootIfUnsaved` | true | Kaydedilmemiş belge varsa reboot yapılmaz |
| `OfficeSaveTimeoutSeconds` | 120 | Reboot öncesi belge kaydetmeyi bekleme süresi |

### Blackout saatine göre restart politikası

| Zaman | Davranış |
|---|---|
| Blackout dışı (gündüz) | Restart **yapılmaz**; ekranda ve Telegram'da sadece bilgilendirme yapılır, karar kullanıcıya kalır. |
| Blackout saatleri (varsayılan 18:00 → 08:00) | Word/Excel/PPT **zorla kapatılır**, restart yapılır (kaydedilmemiş belge kaybolabilir; loglanır ve Telegram'dan bildirilir). |
| Cumartesi-Pazar (tam gün) | Zorla kapatma + restart. |
| `BlackoutEnabled: false` | Blackout kullanılmaz, her saat korumalı davranış. |
| `BlackoutFullDays: []` | Hafta sonu da mesai gibi korunur. |
| `ForceRestartAlways: true` | Saat fark etmez zorla kapatma + restart. |

## Testler

`tests/Test-All.ps1` 5 bölümde testleri koşar (okuma modunda, hiçbir sistem değişikliği yapmaz):

1. Watchdog saf fonksiyonları — blackout penceresi (9 vaka), tatil modları, gün eşleme, **netstat ayrıştırma canlı doğrulaması**, TCP ölçüm, config/state varsayılanları, PS 5.1 dizi açma tuzağı
2. Ayar kapsaması — watchdog config'indeki her anahtar panelde tanımlı mı (otomatik karşılaştırma)
3. Panel veri fonksiyonları — gerçek `last-run.json` ile bağlantı satırları, ölçümler, renkler, rol tespiti
4. İstemci — açık/kapalı port ayrımı (3389 dinleyicisi yoksa atlanır), JSON okuma
5. Uçtan uca — `watchdog -Check` → `last-run.json` → tazelik ve metrics (~40 sn)

Hızlı doğrulama: `.\tests\Test-All.ps1 -Section 1` (veya `-Section 2`).

`ui/RemoteWatchdogPanel.ps1 -SelfTest` arayüzü kurar, PNG önizleme üretir ve şu davranışları doğrular:
X ile kapatma (pencere gizlenir, tray ayakta kalır), sessiz mod, ayar kontrollerinin kaydedilebilirliği
(`Find-AllControls` sayımı).
