# remote-watchdog

> English: [README.en.md](README.en.md) · License: MIT ([LICENSE](LICENSE)) · Katkı: [CONTRIBUTING.md](CONTRIBUTING.md)

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
| `ui/sounds/*.wav` | Panel (kullanıcı oturumu) | Hazır, gerçekçi "uzay filmi" ses efektleri (üretilmiş WAV; panel çalar, elle düzenlenmez) |
| `tools/SfxSynth.cs` | Geliştirme | Efekt sentez motoru: <2 ms attack, inharmonik metalik kısımlar, parlak shimmer reverb, sub katmanı, soft limiter |
| `tools/New-SoundPack.ps1` | Geliştirme | `ui/sounds` paketini yeniden üretir/doğrular (`-List`, `-Verify`) |

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



`ui/RemoteWatchdogPanel.ps1` tek dosyalık bir WPF / XAML uygulamasıdır (tepsi simgesi WinForms `NotifyIcon` ile sağlanır); klavye/fare gerektirmez.

```powershell
.\RemoteWatchdogPanel.ps1                 # tray'de başlar (simgeye çift tıkla = panel)
.\RemoteWatchdogPanel.ps1 -Install        # oturum açılışında otomatik başlat + Başlat menüsü/masaüstü kısayolu
.\RemoteWatchdogPanel.ps1 -SelfTest       # arayüzü kurup doldurup kapatır (test için)
.\ui\Panel-Setup.ps1 -Action Status       # kurulum durumu (Run kaydı, görev, kısayollar)
```

Tepsisindeki simge **duruma göre renklenir**: yeşil (ayakta), kırmızı (sorun), gri (veri yok). Simgeye tıkla,
sağ tıkla: *Şimdi denetle*, *Kontrol panelini aç*, *Sessiz mod*, *Log klasörünü aç*, *Google Remote Desktop*,
*Watchdog kur*, *Teşhis raporu üret*, *Tray'den kapat*. Çift tıklama paneli açar. Tek kopya çalışır (mutex).

Üst çubuktaki **sayaç** sonraki otomatik denetimin kalan süresini **saniye cinsinden** gösterir
(`Otomatik: 03:24 (204 sn)`). Süre dolunca `bekleniyor`, görev gecikirse `gecikti`, elle denetleme sürerken
`Denetleniyor: N sn` yazar; fare ile üzerine gelince aralık, kaynak ve son kontrol saati görünür. Kalan süre
"Bağlantılar" sekmesinin alt satırında ve *Genel durum* ortam bilgisinde de yer alır. *Şimdi denetle* artık
denetimi arka planda çalıştırır: arayüz donmaz, bitince bağlantı/genel durum/bekleyen işler/günlük kendiliğinden
yenilenir (buton ve sayaç geçen süreyi gösterir).

Üst çubuktaki **"Ağı / interneti onar"** düğmesi ağ kademelerini sırayla dener: önce sağlık testi (DNS, HTTPS,
IP) yapılır; her şey yolundaysa hiçbir kademe uygulanmaz (sadece "ağ sağlıklı" raporu yazılır). Sorun varsa
sırayla **DNS önbelleğini temizle → DHCP yenile → ağ adaptörünü yeniden başlat → servis/sürücü →
winsock/IP sıfırla** kademeleri uygulanır; gerekirse makine yeniden başlatma istenir. Ağ sağlığı geri
gelmezse kademe artar, her denemede `lastRepair` alanına hangi kademenin uygulandığı ve ne sonuç verdiği
yazılır (Durum sekmesinde "ağ onarım kademesi"). Düğmeye basınca **"Ağ / interneti onarımı" penceresi**
açılır ve sistem günlüğünden okunan satırlar **canlı** olarak akar (`[WARN] elle ag onarimi basladi…`,
`[INFO] kademe 1/4 basliyor: …`, `kademe 1 uygulandi: …`, `ag onarimi bitti: basarili=…, kademe=…, sure=… sn`),
bitince başlık yeşil `Bitti: BAŞARILI` olur ve balon gider. Penceredeki *Kapat* onarımı iptal etmez.

Onarım **SYSTEM'de** çalışır, panel normal kullanıcı da olsa **UAC penceresi çıkmaz**: panel isteği
`C:\ProgramData\RemoteWatchdog\repair-request.json` dosyasına yazar, sistemdeki iki görevden biri devreye girer:

| Görev | Tetikleyici | Ne yapar |
|---|---|---|
| `RemoteHostRepair` | sadece panel (tetikleyicisiz) | Anında başlar; **panel yönetici/SYSTEM ise** doğrudan bunu çalıştırır |
| `RemoteHostRepairWatch` | her 60 sn | `repair-request.json` varsa onarımı uygular, yoksa ~1 sn'de çıkar. Panel SYSTEM görevini adıyla başlatamadığı için asıl yol budur |

Bu iki görev `RemoteHostWatchdog.ps1 -Install` ile kurulur (`-Uninstall` ile kaldırılır). Ana görevde
`MultipleInstances=IgnoreNew` olduğundan dolayı 5 dakikalık kontrol görevi, çalışırken elle
başlatılamaz; o yüzden onarım için ayrı görevler vardır. `last-run.json` içindeki `repairWatch: 1`
alanı, 60 sn'lik izleyicinin kurulu olduğunu gösterir.

**Kullanıcı yedeği (`RemoteHostWatchdogUser`):** kurumsal yönetim SYSTEM görevlerini siliyorsa diye
aynı kurulum kullanıcı seviyesinde ikinci bir görev de kaydeder (`-UserFallback` ile çalışır).
SYSTEM görevi sağlam ve verisi tazeyken sessiz çıkar (çift çalışma yok); SYSTEM yoksa/eskimişse tam
döngüyü üstlenir (kontrol + onarım + alarm + restart politikası).

**Hızlı yoklama (`RemoteHostFastProbe`):** 5 dakikalık döngü sorunu geç fark eder diye aynı
kurulum her 1 dakikada çalışan hafif bir yoklama da kaydeder (`-FastProbe`). Sadece ağ sağlığına
bakar (IP/DNS/HTTPS/sinyal, birkaç saniye); sağlıklıysa sessiz çıkar, sorun görürse tam döngüyü
hemen tetikler — algılama ~1 dakikaya iner.

**Canlı panel:** `last-run.json` değiştiği anda panel kendini yeniler (1 sn damga yoklaması;
20 sn'lik sayaç yedekte durur) — kapatıp açmak gerekmez. **Ayarlar kaydedilince** watchdog görevi hemen
tetiklenir, yeni ayarlar sıradaki döngüyü beklemez.

**Sesli bildirim (insan sesi):** önemli olaylarda kısa Türkçe anons yapılır — bağlantı sorunu /
düzeldi, onarılıyor / tamamlandı, tekrar başlatılıyor / başlatıldı. Konuşma motoru sırasıyla dener:

1. **edge-tts → doğal KADIN Türkçe (`tr-TR-EmelNeural`)** — Microsoft'un resmî sinir ağı sesi,
   ücretsiz, en doğal telaffuz. Kurulum: `python -m pip install --user edge-tts`. *İnternet gerekir.*
   Panel `tools\edge_tts_win.py` sarmalayıcısını kullanır (edge-tts 7.x + aiodns, Windows'ta
   `WindowsSelectorEventLoopPolicy` gerektiriyor; sarmalayıcı olmadan süreç ses üretmeden çöküyor).
2. **Piper TTS (yerel yedek)** — doğal ama **erkek**; internetsiz çalışır.
   Kurulum: `.\tools\Install-Voice.ps1` → `%LOCALAPPDATA%\RemoteWatchdog\voice`
3. **Windows Türkçe sesi (SAPI)** — Türkçe metin-sesi paketi kuruluysa (Tolga/Emel).
4. Hiçbiri yoksa **susar** — Türkçe metni İngilizce sesle okumaz.

Ayarlar → Bildirim → `SesliBildirim` (aç/kapa) ve `SesliBildirimEdge` (bulut ses açık/kapalı; kapalıysa
doğrudan yerel Piper'a düşer); tepsi *Sessiz mod* açıkken susar. Panel açılışta motoru
`panel.log`'a yazar. Durum kontrolü: `.\tools\Install-Voice.ps1 -Status`

**Film efektleri (`SesEfektleri`, varsayılan açık):** uyarılar ve önemli eylemler artık **iki katmanlı**
duyurulur — önce hazır bir efekt, hemen ardından Türkçe anons. Efektler depoda `ui/sounds/*.wav`
olarak durur (ses aygıtı olmayan makinede bile dosya çalınır; çalınamazsa Windows sistem sesine düşer).
Ses tasarımı istenen hisse göre yapıldı: **net** (2 ms'nin altında attack), **keskin** (4 ms parlak
transient), **parlak** (inharmonik metalik kısımlar + HP shimmer'lı kısa reverb), **gerçekçi**
(sub katmanı, soft limiter ile kırpmasız tepe). Panel efektleri ilk kullanımda yükleyip önbellekte
tutar, bu yüzden olayla ses arasında bekleme olmaz.

| Efekt | Ne zaman | Karakter |
|---|---|---|
| `alert` | bağlantı koptu / kritik alarm | 3 darbeli klakson, metalik kenar, sub baskı |
| `warn` | uyarı: kısmi/başarısız onarım, denetlemede sorun | iki notalı, hafif detoneli gerilimli çınlama |
| `ok` | onay: onarım tamam, denetleme temiz | tek parlak cam ping |
| `recover` | bağlantı düzeldi | yükselen shimmer + çift parlak çınlama |
| `repair` | onarım sürüyor | sonar taraması (yükselen tekrarlı ping) |
| `reboot` | yeniden başlatma istendi/algılandı | alçalan süpürme + sub, tepede net blip |
| `online` | sistem çevrimiçi (kurulum/açılış) | iki notalı cam çan + uzun kuyruk |
| `scan` | elle denetleme başladı | iki mikro blip |

Ayarlar → Bildirim'de **iki ayrı anahtar** vardır ve birbirinden bağımsızdır:
`SesEfektleri` (**hazır wav**, film efektleri) ve `SesliBildirim` (**insan sesi**, Türkçe anons).
Tepsi menüsünde ikisi de tek tıkla açılıp kapanır — *Sesli anons (insan sesi)* ve
*Film efektleri (wav)* (etiketler açık/kapalı durumunu gösterir) — ve *Ses testi* ikisini birden
denetir. Tepsideki *Sessiz mod* ikisini birlikte susturur. Efekt ses seviyesi:
`SesEfektleriVolume` (0-100, 0 = efektler kapalı).

> **Telaffuz notu:** anons metinleri **Türkçe karakterlerle** yazılıdır (`Bağlantı düzeldi.`,
> `Ağ onarılıyor.`) — ASCII yazım (`Baglanti duzeldi`) seslendiricide İngilizce harf gibi okunur ve
> telaffuzu bozar. Kontrol adları `last-run.json`'dan ASCII geldiği için `ConvertTo-TtsText`
> sözlükle Türkçeleştirilir (`Internet erisimi` → `İnternet erişimi`); genel ASCII→diakritik çevirisi
> **yapılmaz** (`internet` → `ınternet` gibi hataları önlemek için). Kısa metinlere sonuna nokta
> eklenir (prozodi için).

```powershell
.\tools\New-SoundPack.ps1 -List       # paket durumu (süre + boyut)
.\tools\New-SoundPack.ps1 -Verify     # dosyalar tam mı (CI testleri de bunu doğrular)
.\tools\New-SoundPack.ps1             # hepsini yeniden üret (ses tasarımı: tools/SfxSynth.cs)
```

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

**4. Günlük** — host ve istemci loglarının son satırları zaman sıralı birleşik ve **renkli**:
**yeşil** = stabil durum (`TAMAM`), **kırmızı** = hata/sorun (`WARN`, `ALERT`, `SORUN`),
**mavi** = bilgilendirme (`INFO`, `ATLANDI`); aynı kural konsol çıktısında da geçerlidir.
*Yenile*, *Log dosyasını aç*, *Tümünü kopyala*,
*Teşhis raporu üret*.


## Host tarafı ne yapar

- **Google Remote Desktop**: `chromoting` servisi durmuşsa başlatır, daemon takılmışsa temiz şekilde yeniden
  başlatır, servisi `Automatic` yapar ve çökerse Windows'un kendini yeniden başlatmasını sağlar
  (`sc.exe failure ... actions= restart/5000/restart/15000/restart/60000`).
  `host.json`/`host_id` yoksa bunu **otomatik çözemez** (cihaz Google listesinden düşer) — loglar ve uyarı
  gönderir, cihazın yeniden kaydedilmesi gerektiğini söyler. Kayıt okunurken önce `host.json`, yetki
  engellenirse aynı klasördeki **`host_unprivileged.json`** kullanılır; böylece yükseltmesiz elle denetimlerde
  (`Şimdi denetle`) kayıtlı cihaz yanlışlıkla "KAYITSIZ" görünmez.
- **Windows RDP**: `fDenyTSConnections`, `RemoteDesktop*` firewall kuralları (dil-bağımsız kural adlarıyla),
  `TermService`/`UmRdpService` durumu ve 3389 dinleme durumu.
- **Sunucu modu**: AC/DC uyku, hibernasyon ve disk zaman aşımlarını kapatır, **Fast Startup**'ı kapatır
  (`powercfg /h off`), ağ adaptörlerinin "cihazı kapatma" modunu kapatıp Wake-on-LAN'ı açar.
- **Saat senkronu**: sunucu saatine göre kayma 120 sn'yi aşarsa `w32tm /resync`.
- **Ağ**: DNS çözümlemesi, genel HTTPS erişimi ve `mtalk.google.com:443` (Google istemci hizmetleri - CRD kaydı için ön koşul, CRD'ye özgü uç değil) kontrolü; takılı adaptörü yeniden başlatır.
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

**Günlük saklama:** `host-watchdog.log` `LogDosyaMB` (varsayılan 2 MB) dolunca
`C:\ProgramData\RemoteWatchdog\log\host-watchdog-<tarih>.log` arşivine taşınır; `LogGunDays`
(varsayılan **30 gün**) günden eski arşivler silinir. Eskiden dosya 5000 satırda kırpılıyordu;
5 dakikalık döngü + 1 dakikalık yoklama günde ~4400 satır ürettiği için tarih penceresi
**sadece ~1 güne** düşüyordu. Artık günlerce birikir ve log yazımı her satırda dosyayı okumaz.

**Konsol penceresi çıkmaması:** Windows Terminal varsayılan terminal olduğunda, zamanlanmış görevden
açılan konsol penceresi Terminal tarafından barındırılır ve `-WindowStyle Hidden` yok sayılır
(siyah/mavi ekranlar bir gelip bir gider). Bu yüzden kullanıcı görevleri (`RemoteHostWatchdogUser`,
`RemoteHostFastProbe`) `wscript.exe` + `host/Start-Hidden.vbs` ile başlatılır — pencere hiç oluşmaz.

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
- **GitHub Actions** alternatifi: repo içinde hazır iş akışı var -
  `.github/workflows/machine-health.yml` (saatte 2 kez, `schedule`). Depo secret'larına
  `HEALTHCHECK_URL`, `TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID` tanımlanınca GitHub'dan makine yoklanır ve
  yanıt vermezse Telegram'a uyarı gider. **Makine kapalı/internetsiz olduğu tek durumu budur**; yerel
  watchdog kendi içinden bakamaz.

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

## Geliştirme: modül yapısı ve sözleşme

```
lib/Common.ps1      paylaşılan yardımcılar (JSON okuma/yazma, TCP ölçümü, gün adı↔sayı dönüşümü)
lib/Contract.ps1    host/client <-> panel arasındaki TEK veri sözleşmesi (schemaVersion + geriye dönük okuyucu)
lib/Settings.ps1    ayar tanımları ($script:Defs, 65 satır) ve yardım balonu metinleri
ui/RemoteWatchdogPanel.ps1   yalnızca arayüz (XAML + olay bağlama)
host/…              kontrol/onarım mantığı (panelden bağımsız)
client/…            istemci tarafı
```

**Sözleşme:** `last-run.json` yalnızca `Write-Status` ile yazılır (`schemaVersion` damgalanır) ve
yalnızca `Read-Status` ile okunur. Okuyucu **sema numarası olmayan eski dosyaları da normalize eder**
(metrics, taskVisible, state.RebootsUtc, config.intervalMinutes eksikse tamamlar). Yani watchdog sürümü
değişse bile eski panel yeni dosyayı okur, yeni panel eski dosyayı okur.

**Yeni kontrol eklemek** (`host/RemoteHostWatchdog.ps1`):
1. `Add-Result 'Ad' $ok $detay $onarim -Metrics @{...}` çağrısı yaz
2. `Invoke-Watchdog` içine bir satır ekle
JSON'a, panele (kart + bağlantı satırı) ve alarm metnine otomatik düşer. Restart tetikleyicisi olmasını
istersen adı `$RebootableProblems` listesine ekle.

**Yeni ayar eklemek** (`lib/Settings.ps1`): `$script:Defs` tablosuna bir satır:
`@{ Sec='Onarim'; Key='FixXyz'; Title='Metin'; Type='bool|int|text|enum|days|lines|csv|datetime' }`
Arayüz, kaydetme ve **"panel kapsaması" testi** otomatik çalışır (eksik anahtar kalmışsa test kırmızıya döner).

**Yeni buton/menü öğesi:** `Add-ActionBar` (`& $mk 'Metin' 'anahtar'`) + `Invoke-SettingsAction`/`Invoke-TrayAction`
switch'i; `New-TrayIcon` içindeki `$items` dizisi.

**Testler:** `tests/Test-All.ps1` (123 kontrol) ve `tests/Test-UI.ps1` (27 kontrol, WPF'yi pencere
göstermeden kurup gerçek `Click` gönderir). Panel görsel regresyonu:
`.\ui\RemoteWatchdogPanel.ps1 -SelfTest -PreviewPage conn -PreviewPath out.png`.
