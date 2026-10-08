´╗┐# Changelog

Bu dosya s├╝r├╝m bazl─▒ de─şi┼şiklikleri tutar. S├╝r├╝m numaras─▒ depodaki `VERSION` dosyas─▒ndad─▒r;
panel ve host betikleri bu dosyay─▒ okur (`-Version` ile sorgulanabilir). S├╝r├╝mleme
[semantic versioning](https://semver.org/lang/tr/) uyumludur.

## [1.3.4] - 2026-10-08

Bu sürüm, **görev yönetiminin (zamanlanmış görev) iş mantığı incelemesinde** bulunan hataları
kapatır. Ölü kod, panelde tuzağa düşüren bir buton ve bir watchdog'un en tehlikeli hata
sınıfı olan **sahte "her şey yolunda"** göstergesi vardı.

### ?? Kritik - düzeltilen

- **Panelde "Zamanlanmış görevi durdur" butonu kalıcı devre dışı bırakıyordu, geri alma yolu
  yoktu.** `stoptask` yalnızca `Disable-ScheduledTask` çağırıyordu; kod tabanında
  `Enable-ScheduledTask` **hiç** çağrılmıyordu. Kullanıcı bir kez basınca görev kalıcı olarak
  kapanıyordu ve "Görevi hemen çalıştır" butonu da devre dışı görevde zorunlu olarak hata
  veriyordu (hata `SilentlyContinue` ile yutuluyordu). "Watchdog kur" butonu ise `Installed`
  true iken pasif olduğu için **panelden hiçbir çıkış kalmıyordu**; kurtarma için
  `Install-Host.ps1` çalıştırmak gerekiyordu. Buton artık **iki yönlü**: görev açıksa
  devre dışı bırakır, devre dışıysa **yeniden açar** ("Gorevi yeniden ac").
- **Düğmelerin "çalışıyor / durdur" durumu hiç hesaplanmıyordu.** `Update-ActionBarColors`
  içinde `$running` **hiçbir yerde atanmıyordu**, ama hem stop hem run butonu onu kullanıyordu.
  Sonuç: "dur dur" butonu kalıcı pasif, "hemen çalıştır" butonu kalıcı açık. Artık
  `$running = $st.Running`.
- **Devre dışı bırakılmış görev, yönetici olmayan panelde yeşil "çalışıyor" görünüyordu.**
  `taskInstalled` yalnızca döngü **çalışırken** yazılıyor; görev kapatılınca döngü duruyor ve
  JSON'daki `true` **kalıcı donuyordu**. Yönetici olmayan panelde `Get-ScheduledTask` boş
  döndüğü için karar JSON'a göre veriliyordu: watchdog tamamen kapalıyken panel "Görev:
  çalışıyor" diyordu. Artık "Bekleyen işler" listesinde **ayrı bir kırmızı kart** çıkıyor
  ("Zamanlanmıs gorev DEVRE DISI birakildi") ve "Kur" butonu da yeniden kurulabilir hâle
  geldi.
- **`last-run.json` atomik yazılmıyordu → sahte yeşil "Bekleyen iş yok".** `Write-Status`
  doğrudan `WriteAllText` ile yazıyordu; panel tam yazma anında okuduğunda JSON parse hatası
  alıp `null` dönüyordu. `Get-Actions` bu `null` üzerine devam ediyor, tüm kartları (checks,
  docs-block, netResetPendingReboot, consecutiveFailures) sessizce yutuyor ve kullanıcıya
  **"Bekleyen is yok / Her şey yolunda"** gösteriyordu - bir watchdog için en tehlikeli hata
  sınıfı: **olmayan alarm**. Artık yazım geçici dosya + `File.Replace` ile tek hamlede
  yapılıyor (hedef dosyanın ACL'i korunur) ve `Get-Actions` ikinci okumada tekrar null
  kontrolü yapıyor.

### ?? Yüksek - düzeltilen

- **"Watchdog dönmüyor" kartı hiçbir zaman çıkmıyordu (ölü kod).** `Get-Actions` içinde `$st`
  önce `Get-StatusInfo` sonucuydu (`.Age` alanı var), hemen ardından `Get-WatchdogTaskState`
  ile **eziliyordu**; görev durumu nesnesinde `Age` alanı hiç yoktu. `Get-StatusTaskState`
  artık `Age` / `AgeMinutes` / `Disabled` döndürüyor. Eşik de düzeltildi: `IntervalMinutes`
  okunamazsa `0`'a düşüyor ve kart her zaman görünüyordu; taban 10 dk.
- **Kullanıcı yedeği, ayarlanan kontrol aralığını hiç dikkate almıyordu.**
  `Test-SystemWatchdogActive` eşiği `$IntervalMinutes` **script parametresinden**
  (sabit 5) okuyordu; `-UserFallback` görevi yalnızca `-UserFallback` argümanıyla çağrıldığı
  için parametre her zaman 5 geliyordu. Aralık 30 dk'a çekildiğinde eşik 12 dk'da kalırken
  SYSTEM görevi 30 dk'da bir koşuyordu → kullanıcı yedeği **sürekli "SYSTEM ölü" sanıp**
  devreye giriyor, `admin=False` tam döngüler açılıyordu (onarım kademeleri ve zorla restart
  çalışmıyor, restart bütçesi sahte sayımlarla doluyordu). Artık komut satırında açıkça
  verilen değer, yoksa **ayar dosyasındaki gerçek aralık** okunuyor (aynı desen
  `Get-FullCycleBackoffMinutes` içinde zaten vardı) ve eşik 45 dk ile sınırlanıyor.
- **Ayar, her yeniden kurulumda sessizce 5 dakikaya dönüyordu.** `Install-Watchdog` aralığı
  yalnızca görev tetikleyicisine yazıyordu, `config.json``a değil; panelden "Watchdog kur"
  denildiğinde `-IntervalMinutes` **argümanı gönderilmiyordu** ve görev parametre varsayılanı
  5'e dönüyordu. Artık aralık **config'e de yazılıyor** ve panel aralığı kurulum komutuna
  geçiriyor; `Test-SystemWatchdogActive` eşiği, geri sayım ve panelin sayacı hepsi aynı
  değere bakıyor.
- **Onarım akışı yarıda kesiliyor, panel "başlamadı" diyordu.** `RemoteHostRepairWatch` görevinin
  `ExecutionTimeLimit`'i 5 dakikaydı; `Invoke-NetworkRepairFlow` ise `LastRepair`'i ve "ağ onarımı
  bitti" özet satırını **kademeler bittikten sonra** yazıyor. 5 dk'ta öldürülen akış yarıda
  kaldığı için özet hiç yazılmıyor, panel 7 dk bekleyip **"başlamadı"** diyordu (halbuki
  başlamış ve belki kısmî onarım uygulanmıştı), `LastRepair` olmadığı için
  `Write-RepairStatusPatch` ve Telegram bildirimi de çalışmıyordu. Görev artık **sınırsız**;
  panelin canlı penceresi 22 dk bekliyor ve **başladıysa "bitmedi"**, başlamadıysa
  "başlamadı" ayrımını yapıyor.
- **Onarım akışının kilidi yoktu → iki paralel kademe uygulaması.**
  `Global\RemoteWatchdogCycle` yalnızca tam döngüyü koruyor; `Invoke-NetworkRepairFlow`
  korumasızdı. `repair-request.json`'u üç ayrı tüketici okuyor (`Test-NetworkLayer`,
  `Invoke-Watchdog`, `-RepairWatch`) ve panel isteği yazdıktan sonra `RemoteHostRepair`'i de
  başlatıyor. Artık akış `Global\RemoteWatchdogRepair` kilidiyle sarılıyor; kilit meşgulse
  kademe uygulanmıyor ve sonuç "başka bir onarım sürüyor" olarak dürüstçe bildiriliyor.
- **Yarım yazılmış onarım isteği sessizce yok oluyordu.** `Read-RepairRequest` parse hatasını
  yutuyor ve dosyayı **yine de** siliyordu; panel "Ağı onar" dediğinde istek yazılırken
  yarım dosya okunursa hiçbir şey olmuyordu. Artık dosya yalnızca başarıyla okunduğunda
  siliniyor, aksi hâlde 60 sn'lik izleyici sonraki turda tekrar deniyor.

### ?? Orta - düzeltilen

- **Kurulumdaki self-heal ölü koddu.** `Install-Watchdog` içindeki varlık kontrolü, hemen bir
  üst satırdaki `Register-ScheduledTask`'tan sonra çalıştığı için teorik olarak **hiç**
  tetiklenemiyordu (yanıltıcı güvence). Artık **devre dışı bırakılmış** görevi de onarıyor:
  paneldeki "Durdur" ya da kurum politikası görevi kapatırsa, kurulum "KAYIT-TAMAM" dese bile
  watchdog sessizce çalışmıyordu.
- **Token, güvenli kanaldan gelip komut satırına sızıyordu.** `Install-Watchdog` önce token
  dosyasını okuyup **silip**, sonra yönetici değilsek `-TelegramToken`'i `$forward` içine
  açıkça koyuyordu. Yetki kontrolü artık **en başta**; yükseltilen sürece token **dosyasının
  yolu** geçiriliyor (`Start-Process -Verb RunAs` aynı kullanıcıyı yükselttiği için DPAPI
  dosyası yine çözülüyor). `-TelegramToken` yalnızca çağıran zaten komut satırında kullandığında
  devreye giriyor ve uyarı yazıyor.
- **Panel görev durumu 60 sn cache'leniyordu ve her işlemden sonra düşürülmüyordu.**
  Kurulum, kaldırma, devre dışı bırakma ve ayar kaydından sonra butonlar **eski** durumu
  gösteriyordu; kullanıcı işlem yaptığı halde butonun değişmediğini görüp tekrar tekrar
  basıyordu. `Update-TaskCache` eklendi ve tüm durum değiştiren işlemlerden sonra çağrılıyor.
- **Görev butonlarının hataları yutuluyordu.** `Disable-ScheduledTask` / `Start-ScheduledTask`
  çağrıları `-ErrorAction SilentlyContinue` ile sessizce geçiyordu: yetki yoksa veya görev
  yoksa düğmeye basmak hiçbir şey yapmıyordu. Artık `-ErrorAction Stop` + kullanıcıya
  görünür hata mesajı. Ayrıca yönetici olmayan panelde SYSTEM görevi görünmediği için
  bu iki buton **pasif** kalıyor ve nedeni tooltip'te yazılı.
- **`Get-StatusTaskState` "kurulu değil" dalında `Visible = $true` dönüyordu** (alan anlam
  çelişkisi; görev yokken görünür olamaz). Artık `false`.
- `Get-Actions` içindeki "kurulu" kartının rengi artık görevin **gerçek** durumundan geliyor;
  önce sabit `ok` idi, devre dışı bırakılmış görev de yeşil "kurulu" kartını gösteriyordu.

### 🔍 Öz-review sonrası ek düzeltmeler

Bu sürümdeki düzeltmeler yayınlanmadan önce eleştirel gözden geçirildi ve birkaç kusur daha
kapatıldı (biri, aralık düzeltmesinin **etkisiz kalmasına** yol açan bir PowerShell tuzağıydı):

- **`$PSBoundParameters` tuzağı.** İç fonksiyonlarda `$PSBoundParameters` **boş** döner
  (yalnızca fonksiyonun kendi parametrelerini tutar; çağıranın değil). "Aralık açıkça verildi mi?"
  sorusu `Install-Watchdog`/`Test-SystemWatchdogActive` içinde bu yüzden **her zaman "hayır"**
  oluyordu. `Install-Watchdog`'da bu, açıkça verilen `-IntervalMinutes 30` değerini **yok
  sayıp** config'e düşürüyordu. Çözüm: karar **script kapsamında** (dispatcher) verilir;
  `Install-Watchdog` artık `param([int]$IntervalMinutes = 0)` alır (0 = "belirtilmedi" sentinel'i)
  ve aralığı last-run.json → config → 5 sırasıyla çözer. `Test-SystemWatchdogActive` de artık
  görevin **gerçekten** kullandığı aralığı (last-run.json) okur; eski kurulumlarda config
  eksik olsa bile doğru eşiği bulur.
- **Yükseltme yolu aralığı sıfırlıyordu.** Hem `RemoteHostWatchdog.ps1`'in kendi
  `Start-Process -Verb RunAs` yönlendirmesi hem de `Install-Host.ps1`'in kendi kendini
  yükseltmesi, varsayılan 5 dk'yı **zorla** çocuk sürece geçiriyordu (çünkü `$PSBoundParameters`
  yükseltilmiş kopyada dolu görünür). Artık aralık yalnızca **kullanıcı açıkça verdiyse**
  taşınıyor; aksi hâlde config korunuyor.
- **Otomatik onarım kademesi kilit dışıydı.** `Test-NetworkLayer` içindeki otomatik
  `Invoke-NetworkRepair` çağrısı, akış kilidini atlıyordu; 60 sn'lik izleyici ile döngü aynı
  anda adaptör/winsock değiştirebiliyordu. Yeni `Invoke-RepairRungLocked`, kademeyi aynı
  `Global\RemoteWatchdogRepair` kilidiyle sarar.
- **Panelde "Görevi hemen çalıştır" devre dışı görevde etkin görünüyordu** (tooltip "DEVRE DIŞI"
  derken düğme aktif ve tıklama boşa gidiyordu). Artık devre dışıyken pasif ve nedeni yazılı.
- **`Get-RepairReport`, onarım kilitli olduğu için atlandığında** "KISMİ/BAŞARISIZ" diyordu;
  artık `busy` alanını tanıyıp **"ATLANDI (başka onarım sürüyordu)"** gösteriyor.

### 🧪 Test

- `tests/Test-All.ps1` **368 kontrol** (0 hata): görevi yeniden açabilme, `$running`
  hesabı, atomik JSON yazımı, onarım kilidi, sınırsız RepairWatch, etkinlik eşiğinin görevin
  gerçek aralığını okuması, kurulum aralığının config'e yazılması ve **script kapsamında +
  sentinel parametreyle** çözülmesi (regresyon), token'ın dosya yoluyla geçirilmesi.
- `tests/Test-UI.ps1` **54 kontrol** (0 hata): görev durumu matrisi bozulmadı.

## [1.3.3] - 2026-10-07

Bu sürüm, **güvenlik planındaki üç kritik maddeyi kapatır** (aşağıdaki `[Unreleased]`
bölümüne bakın — plan artık uygulandı, kayıt burada). Üçü de "kimse fark etmeden
çalışıyordu" türdendi: bot token'ı düz metin duruyordu, bir VBS betiği komut enjeksiyonuna
açıktı ve indirilen kod hiç doğrulanmıyordu.

### 🔴 Güvenlik — düzeltilen

- **Telegram token'ı artık DPAPI ile şifreli** (`lib/Common.ps1` → `Protect-RwSecret` /
  `Unprotect-RwSecret`). Kapsam bilinçli olarak **LocalMachine**: `config.json`'u **panel
  (kullanıcı hesabı) yazıyor** ama **SYSTEM watchdog okuyor**; `CurrentUser` kapsamı
  SYSTEM'in çözmesini engellerdi ve alarm sessizce susardı. LocalMachine hem iki hesabı
  hem de "başka makineye taşınmış yedek" senaryosunu korur.
  Host/client/panelin **hepsi** okurken çözer, yazarken şifreler — panel bir sonraki
  "Kaydet"te token'ı düz metne geri yazmaz.
- **Token komut satırından kaldırıldı.** `Install-Host.ps1` / `Install-Client.ps1`
  artık `-TelegramTokenFile` kullanıyor: geçici dosyaya **DPAPI ile** yazılır, hedefe
  **parametre olarak değil dosya yoluyla** geçer, okunur okunmaz **silinir**. İşlem listesi
  (`Get-Process`/Task Manager) ve 4688 olay günlüğünde token görünmez. Elle çalıştırmada
  `-TelegramToken` geriye dönük uyum için duruyor.
- **`Start-Hidden.vbs` parametre enjeksiyonu kapatıldı.** Betik yolu tırnaklıydı ama
  **parametreler tırnaksız** birleştiriliyordu (`cmd & " " & Arguments(i)`); `&`, `|` veya
  `"` içeren bir değer komut enjeksiyonu yapıyordu. Artık her argüman `QuoteArg()` ile
  sarılıyor, içteki tırnaklar `""` ile kaçırılıyor. *Canlı doğrulandı: `a&b|c` ve
  `&calc.exe` artık tek argüman olarak geçiyor.*
- **SHA256 doğrulaması eklendi** (`tools\Verify-Hashes.ps1` + `hashes.sha256.json`).
  Kurulum betikleri çalıştırılacak koddan **önce** tüm dosyaları doğrular ve tutmuyorsa
  **kurulumu durdurur** (`-SkipHash` yalnızca güvendiğiniz kopyadan kurarken).
  *Bozuk dosya test edildi: `[BOZUK]` + çıkış kodu 1.* README'deki hashsiz `irm` tek satır
  indirme kaldırıldı, yerine doğrulama adımı kondu.

### Testler

`Test-All 357/0`, `Test-UI 54/0`, panel `-SelfTest` temiz. 33 yeni regresyon testi;
DPAPI için gerçek `config.json` üzerinde gidiş-dönüş ve geriye dönük uyum sınandı
(eskiden düz metin kayıtlı değerler bozulmadan okunuyor).

## [Unreleased] — Planlanan (v1.4.0 hedefi)

> **Durum:** aşağıdaki üç kritik güvenlik maddesi **1.3.3'te uygulandı** (yukarıya bakın).
> Bu bölüm, çözüm tasarımını ve gerekçeleri kayıt altında tutar; kalan izleme maddeleri
> günceldir.

### 🔴 Kritik — güvenlik (✅ 1.3.3'te uygulandı)

**1. Telegram token'ları düz metin saklanıyor (config.json + komut satırı sızıntısı)**

- **Bulgu:** `config.json` içindeki `TelegramToken` şifreli değil; dosya ACL'i
  `BUILTIN\Users → ReadAndExecute` verdiği için **her yerel kullanıcı okuyabilir**. Ayrıca
  `install\Install-Host.ps1` ve `host\RemoteHostWatchdog.ps1 -Install` token'ı **komut
  satırından** geçiriyor; işlem listesi (`Get-Process`, Task Manager) ve 4688 olay günlüğü
  üzerinden sızabilir. `Send-Telegram` her çağrıda bu değeri okuyor.
- **Çözüm:**
  1. Token'ı **DPAPI** ile koru: `ConvertFrom-SecureString` / `ConvertTo-SecureString`
     (`-Key` veya makine/servis kapsamı). `Get-Config` okurken çözer, `Set-Config`
     yazarken şifreler. Mevcut düz metin değerler ilk çalıştırmada otomatik dönüştürülür
     (geriye dönük uyum).
  2. Kurulum betiğinde `-TelegramToken` **komut satırından kaldır**; istenirse
     `Read-Host -AsSecureString` ile veya tek seferlik `telegram-token.txt` dosyasından
     okunup hemen silinerek alınır. `Get-CimInstance Win32_Process` çıktısında token
     görünmemeli.
  3. `Send-Telegram` içinde çağrı zincirine token sızdıran `Write-Log`/`Write-Host`
     yokluğunu doğrula; hata mesajları URL içerebilir, `Send-Telegram`'e özel
     log-redaksiyonu ekle.
  4. `config.json` ACL'ini daralt: `BUILTIN\Users` → yalnızca okuma kalabilir ama token
     alanı şifreli olacağı için asıl koruma DPAPI'de; yine de `icacls` ile
     kullanıcıyı dosya sahibi yapar.

**2. VBScript parametre enjeksiyonu (`host/Start-Hidden.vbs`)**

- **Bulgu:** `Start-Hidden.vbs:29` → `cmd = cmd & " " & WScript.Arguments(i)`.
  Argümanlar **tırnaksız** birleştiriliyor. Değer `&`, `|` veya `"` içerirse komut
  enjeksiyonu olur. Betik yolu (`WScript.Arguments(0)`) doğru tırnaklı, **parametreler değil**.
- **Çözüm:** Her argümanı çift tırnakla sar ve içteki `"` karakterlerini `""` ile kaçır:
  ```vbscript
  Function Quote(s)   ' VBScript'te Function: (Parametreler) yapisi farklidir
      Quote = """" & Replace(CStr(s), """", """""") & """"
  End Function
  cmd = cmd & " " & Quote(WScript.Arguments(i))
  ```
  VBScript'te fonksiyon `Function Quote(s)` şeklinde tanımlanır; `Replace(s, find, replace)`
  kullanılır. Ek olarak bu yol yalnızca **sabit, kod içinden** verilen argümanlarla
  çağrıldığı için saldırı yüzeyi dardır — yine de savunma katmanı olarak kapatılmalıdır.

**3. İndirilen dosya hash doğrulaması yok (MITM riski)**

- **Bulgu:** `README.md:237` ve `:281` `irm https://raw.githubusercontent.com/... -OutFile`
  ile tek satır indirme yapıyor ve indirilen betik `-ExecutionPolicy Bypass` ile
  çalıştırılıyor. **Doğrulama yok**; ağ MITM'i veya ele geçirilmiş depo erişimi
  keyfi kod çalıştırmaya yol açar. `irm` PowerShell 5.1'de TLS 1.2'yi zorlamaz.
- **Çözüm:**
  1. Kurulum talimatlarına indirme sonrası **SHA256 doğrulaması** ekle:
     `irm <url> -OutFile f.tmp; (Get-FileHash f.tmp -Algorithm SHA256).Hash -eq <yayınlanan hash>`.
     Hash'ler sürüm başına `host/RemoteHostWatchdog.ps1.sha256` ve
     `client/RemoteClientWatchdog.ps1.sha256` dosyalarında tutulur; kurulum betikleri
     `New-SoundPack.ps1 -Verify` benzeri bir `-Verify` adımıyla bunları doğrular.
  2. `irm` yerine `[Net.ServicePointManager]::SecurityProtocol = Tls12` zorlayan bir
     yardımcı kullan (betiklerde zaten var) ve indirmeyi TLS 1.2'ye sabitle.
  3. Kurulum betiklerine `-VerifyHash` seçeneği: sağlama başarısızsa **kurulumu durdur**.
  4. Uzun vadede imzalı yayın (GitHub Release + `minisign`/GPG) tercih edilebilir; ancak
     DPAPI/ACL zorunlu olduğu için hash doğrulaması asgari çözümdür.

### Notlar / izleme maddeleri

- `Verify-OutageLogic.ps1` bu ortamda önceden mevcut olan **5 kırmızı** test içeriyor
  (bütçe mutabakatı / `MinOutageMinutes` eşiği). v1.3.2 ve öncesi `HEAD` sürümlerinde de
  aynı 5 test kırmızı; v1.4.0'da ayrı bir iş olarak ele alınacak.
- `Test-SystemWatchdogActive` yanlış pozitif verebiliyor (bkz. 1.3.2 "Bilinen").
- `host/Enable-ConsoleAutoLogon.ps1` parolayı registry'de düz metin saklıyor
  (opt-in, riskli) — bu planın kapsamı dışında ama bilinçli bir istisna olarak duruyor.

## [1.3.2] - 2026-10-01

Bu sürüm, 30.09 22:48 – 01.10 05:25 arasında yaşanan **6,5 saatlik kesintide restart'ın
hiç gerçekleşmemesine** yol açan dört hatayı giderir. O gece günlükte `geri sayimi basladi`
**325 kez**, `geri sayim bitti` **0 kez** sayıldı; `shutdown.exe` hiç çağrılmadı ve makineyi
ancak Windows Update (`MoUsoCoreWorker.exe`) kapatabildi.

### Düzeltilen
- **Geri sayım döngüsü DNS'te kilitleniyordu (asıl sebep):** döngüdeki toparlanma kontrolü
  `Invoke-Probe` (→ `Invoke-WebRequest`) çağırıyordu ve bu çağrı **hostname çözümlemesi** yapıyor.
  `Invoke-WebRequest -TimeoutSec` **DNS beklemesini kapsamaz**; yönlendirici asılı kaldığında tek
  çağrı bu makinede ölçüldüğü üzere **11–30 sn** bloklanıyor, 30 sn'lik sayaç ~50 sn'ye uzuyor ve
  döngü hiç bitmiyordu. Aynı hata `Test-RecoveryBeforeReboot`'ta zaten düzeltilmişti, geri sayıma
  uygulanmamıştı. Artık döngü **yalnızca `Get-TcpMs`** kullanıyor (sert zaman aşımlı, doğrudan IP).
- **`shutdown.exe` argüman tırnak hatası (yumuşak restart hiç çalışmamıştı):** `Start-Process`
  `-ArgumentList` dizisini **tırnaksız** birleştiriyordu:
  `/c RemoteHostWatchdog: onarilamayan baglanti sorunu` → `shutdown.exe` dokuz argüman görüyor,
  `/c` yalnızca `RemoteHostWatchdog:` metnini alıyor, kalan kelimeler **geçersiz parametre** oluyor
  ve komut **çıkış kodu 1** ile başarısız oluyordu. Artık argüman **tek tırnaklı string** ve `/c`
  metni iç tırnaklı. **Her iki `shutdown` çağrısında da çıkış kodu kontrol ediliyor** — önceki
  zorla (`/f`) yolunda hiç kontrol edilmediği için başarısız olsa bile "iletildi" yazıyordu.
- **Restart, sayaç sürecine bağımlıydı:** sayaç yapan süreç ölürse/oturum kapanırsa restart da
  kayboluyordu. Artık karar ve eylem **deadline tabanlı, SYSTEM + Highest yetkili, tek seferlik**
  `RemoteHostDeadlineReboot` görevine devrediliyor (`Start-DeadlineRebootGuard` /
  `Invoke-DeadlineReboot`). Sayaç yalnızca kullanıcıyı bilgilendiren bir görünüm; iptal ve
  "internet döndü" yollarında görev kaldırılıyor. Sayaç ve nöbetçi **aynı anda tetiklenmiyor**
  (`Test-DeadlineRebootGuardArmed`) — bu çift çağrı canlı testte `cikis kodu 1` olarak görüldü.
- **Zorla restart kademeleri eklendi:** `shutdown /r /f /t 0` (uygulamaları kapatır), yönetici
  yoksa atlanıp loglanan WMI/RASD, ve son çare `bcdedit bootstatuspolicy` + `/f`. Restart
  "iletildi" deyip **etkisiz kalabiliyordu**; nöbetçi artık açılış zamanını 24 sn doğruluyor,
  değişmediyse `Confirm-Reboot -ForceOnly` ile tırmanıyor, o da olmazsa
  "elle müdahale gerekli" yazıyor.
- **FastProbe yetkisi `Limited` idi:** `Start-FullCycle` ile başlatılan döngüler `admin=False`
  koşuyordu; onarım kademeleri "admin gerekir" diye atlanıyor, zorla restart yöntemleri
  kullanılamıyordu. `RunLevel: Highest`.
- **Ana SYSTEM görevi kaybolmuştu:** `install-debug.txt` "KAYIT-TAMAM" demesine rağmen
  `RemoteHostWatchdog` görevi kayıtlı değildi; watchdog yalnızca açık oturuma bağımlıydı.
  Artık hem kurulumda hem **her döngüde** varlığı doğrulanıp yoksa yeniden kuruluyor.
- **Nöbetçi iptal onayı (`reboot-ack.json`) yazmıyordu:** nöbetçinin var oluş sebebi
  "sayaç süreci ölmüş olabilir" halidir; bu halde ack'ı yazacak başka aktör yoktur. Panel
  ack'ı görmediği için iptal gerçekleşmiş olsa bile **"İptal onaylanmadı, geri sayım
  sürüyor"** diyordu. Artık `Confirm-DeadlineCancel` ack'ı yazar, iptal/bekleyen dosyalarını
  temizler ve görevi kaldırır.
- **İptal yarışı:** nöbetçi başladıktan SONRA panelden iptal edilirse, sayaç süreci iptal
  dosyasını kaldırırken nöbetçi çoktan iptal kontrolünü geçmiş olabiliyordu. Nöbetçi artık
  `Confirm-Reboot`'tan hemen önce iptal bayrağını **tekrar** kontrol ediyor.
- **Toparlanma iptali yanlış kapsamdaydı:** "geri sayım sırasında internet dönerse iptal et"
  mantığı **tüm** restart yollarına uygulanıyordu; paneldeki "Şimdi zorla kapat ve yeniden
  başlat" çevrimiçi makinede bu yüzden hiç çalışmıyordu. Artık yalnızca kesinti kaynaklı
  restart `-CancelOnRecovery` taşıyor; kullanıcı/panel restart'ı internet sağlıklı olsa bile
  uygulanıyor.

### Bilinen (ayrı konu)
- `Test-SystemWatchdogActive` yanlış pozitif verebiliyor: `RemoteHostWatchdogUser` görevi
  `RunLevel: Highest` olduğu için yazdığı `system-heartbeat.json`, SYSTEM görevi sağlammış gibi
  görünüyor. Yukarıdaki kendini onarma `Get-ScheduledTask`'ı doğrudan sorguladığı için bu
  bulanıklıktan etkilenmiyor, ama fonksiyonun kendisi hâlâ taşıyor.

## [1.3.1] - 2026-09-30

### Düzeltilen
- **"İptal edildi" deniyordu ama restart gerçekleşiyordu:** geri sayım tek seferde
  `Start-Sleep` ile bekliyordu, iptal bayrağı **sadece süre bitince** kontrol ediliyordu; arada
  `-ForceReboot` yolu ayrı bir `shutdown.exe /r /t` çağırıyordu ve panel hangi restart'i izlediğini
  bilemiyordu. Artık tüm restart yolları (otomatik karar **ve** paneldeki "Şimdi zorla kapat")
  `Start-CountdownReboot` üzerinden geçiyor; geri sayım **0,5 sn'de bir iptal dosyasına bakıyor**,
  sayı bittikten sonra da 2 sn ek kontrol var. Aynı anda iki ayrı pencere/kutu çıkmıyor.
- **İptal gerçekleşmeden "durduruldu" deniyordu:** panel iptal dosyasını yazınca hemen başarı
  bildiriyordu. Artık **SYSTEM'deki watchdog'ın onayını bekliyor** (`reboot-ack.json`); onay gelmezse
  "İptal onaylanmadı, geri sayım sürüyor" deyip butonu geri açıyor. Yani "durduruldu" yalnızca
  gerçekten durduğunda söyleniyor.
- **Anons duyulmuyordu:** iptal onayı `MessageBox` ile veriliyordu; modal pencere panelin
  dispatcher'ını kilitleyip sayaç anonslarını (30/15/10/5) ve sesli anonsu engelliyordu. Onay artık
  **balon + ses** ile veriliyor, `MessageBox` tamamen kalktı. Aynı sebeple buton işleyicileri
  `try/catch` içine alındı — kapsam hatası (`IsEnabled` bulunamadı) panelde hata kutusu çıkarıyordu.
- **İki ayrı bildirim kutusu:** restart iptalinde `msg.exe` (10 dakika açık kalan pencere) **ve**
  `MessageBox` birlikte çıkıyordu. `msg.exe` artık restart yollarında kullanılmıyor; bilgi panelin
  balonu ve anonsu ile veriliyor, Telegram'a gider.
- **Yanıltıcı metin:** blackout dışındayken/devre kesici devreye girdiğinde "Otomatik restart
  durduruldu" yazılıyordu — oysa restart **hiç denenmemişti**. Artık "yeniden başlatma yapılmayacak:
  <sebep>" deniyor.

### Birleştirilen (1.2.4)
Bu sürüm, aynı gün çözülen **restart gerçekleşmiyordu / "3 kez restart oldu" deniyordu** ve
**bildirim birikimi** düzeltmelerini de içerir. Bunlar 1.3.x'in iptal edilebilir geri sayım
penceresiyle birleştirildi:
- Geri sayım sonunda doğrudan `shutdown.exe /r /t 0` çağrılması yerine **`Confirm-Reboot`**
  kullanılıyor (çıkış kodu kontrolü + WMI + `Restart-Computer` yedeği, hangisinin restart
  ilettiği loglanır). Restart bütçesi yalnızca `PendingRebootUtc` ile damgalanıyor; bütçe kaydı
  ancak makine gerçekten yeniden açıldığında (`LastBootUtc` değişti) yazılıyor. İptal ve
  toparlanma yolları `Invoke-StateUpdate` ile atomik temizleniyor.
- Geri sayımdaki toparlanma kontrolü önce **sert zaman aşımlı TCP** ile yapılıyor (DNS'te
  asılmıyor); 1.1.1.1 engelli ağlarda HTTP yoklamasına düşüyor.
- Hızlı varsayılanlar (`RebootAfterFailedCycles=1`, `RebootDelaySeconds=30`, `MinOutageMinutes=0`,
  `MinUptimeMinutes=3`, `RebootCooldownMinutes=2`), hızlı yoklama, konu bazlı bildirim kısıtı,
  atomik durum yazımı, `Invoke-CycleLocked` ile çift döngü engeli ve `system-heartbeat.json` ile
  SYSTEM görünürlüğü. Ayrıntı için aşağıdaki [1.2.4] bölümüne bakınız.

## [1.3.0] - 2026-09-30

### Eklenen
- **Geri sayaclı, iptal edilebilir restart uyarısı:** onarılamayan bağlantı sorununda artık
  **Windows'un kendi diyaloğu değil**, panelin açtığı bir modal çıkıyor: büyük saniye geri sayacı
  (`m:ss`), sorunun adı ve iki düğme — **"İptal et — şimdi yeniden başlatma"** ve
  **"Şimdi yeniden başlat"**. Daha önce `shutdown.exe /r /t` çağrısı doğrudan Windows'un sistem
  penceresini açıyordu; sayı panelde görünmüyor, kullanıcı müdahale edemiyordu.
  - Host önce `reboot-pending.json` yazıyor (deadline, süre, sorunlar), panel bunu 1 sn'lik
    döngüde fark edip modalı açıyor, ardından geri sayım dolunca `shutdown /r /t 0` tetikleniyor.
  - **İptal** `shutdown /a` gönderir + `reboot-cancel.flag` yazar; SYSTEM'deki watchdog geri
    sayım sonunda bu dosyayı görüp restart etmez, `ConsecutiveFailures` sıfırlanır (5 dk sonra
    aynı soru tekrar sorulmaz). Panel açık değilse de eski güvenli davranış korunur: geri sayım
    yine işler ve cihaz kapanır.
  - Modal `Topmost`, kapatılamaz (X yalnızca arka planı temizler) ve tekrarlanmaz (aynı dosya
    için ikinci kez açılmaz).

### Düzeltilen
- **"Bilgisayar yeniden başlatılacak" anonsu duyulmuyordu:** restart anonsu yalnızca
  `pending-voice.json`'a yazılıyor, panel de kapanacağı için **okunmadan kayboluyordu**. Artık
  modal açılırken anons **doğrudan konuşulur** ("Onarılamayan bağlantı sorunu. Bilgisayar N
  saniye sonra yeniden başlatılacak. İptal edebilirsiniz."), kalan süre **30 / 15 / 10 / 5
  saniyelerde** tekrar tekrar anonslanır, son 10 saniyede sayaç kırmızıya döner. İptal edilirse
  "Yeniden başlatma iptal edildi" anonsu verilir ve bekleyen anons dosyası silinir (yoksa yeni
  panel açılınca "yeniden başlatılıyor" derdi). Host da aynı anonsu dosyaya yazar, panel kapalıysa
  yeni panelde okunur.

## [1.2.4] - 2026-09-30

### Düzeltilen
- **Geri sayım yeni kesintiyi de bastırıyordu (kendi eklediğim regresyon, düzeltildi):** canlı
  yoklama geri sayımı "son tam döngüden beri geçen süre"ye bakıyordu. Ag 1 dakika önce
  tetiklenmiş bir döngüden sonra 2 dakika önce sağlıklıysa ve şimdi koptuysa, **yeni** kesinti
  geri sayımda kalıyor, "ağ sorunu algılandı" anonsu hiç duyulmuyor ve onarım 3 dakika
  gecikmeli başlıyordu. Artık geri sayım **yalnızca kesinti zaten sürerken** (önceki yoklama
  `bad` ise) geçerli; yeni kesinti ve "bağlantı düzeldi" geçişi her zaman beklemez.
  `fullAt` damgası da artık sağlıklı durumda yazılmıyor (yalnızca gerçek tetiklemede).
- **Restart gerçekleşmiyordu, üstelik "3 kez restart oldu" deniyordu.** 30.09 gecesi
  (01:28–09:17 arası) internet 8 saat kesildi; günlük 3 kez *"yeniden başlatma tetiklendi"*
  yazdı ama makine **hiç restart olmadı** (sistem olay günlüğünde `shutdown.exe` için 1074 kaydı
  yok, uptime 815dk→906dk arası kesintisiz artıyordu). Yine de 24 saatlik restart bütçesi
  "3/3 dolu" sayılıp **devre kesici 24 saat boyunca her şeyi reddetti**: gerçek bir kesintide
  sistem hiçbir şey yapamaz hale gelmişti. Üç ayrı sebep birleşiyordu:
  1. Bütçe **restart gerçekleşmeden önce** yazılıyordu. Geri sayımda iptal edilirse kayıt
     siliniyordu; ama süreç geri sayımın ortasında kaybolursa veya `shutdown.exe` sessizce
     başarısız olursa kayıt **kalıcı** olarak bütçeyi yakıyordu. Artık restart istendiğinde
     sadece `PendingRebootUtc` damgalanıyor; bütçe kaydı **makine gerçekten yeniden açıldığında**
     (`LastBootUtc` değiştiğinde) yazılıyor. Açılmadıysa kayıt silinip uyarıyla log'a düşüyor.
  2. `shutdown.exe /r /t 0` hatası `2>&1 | Out-Null` ile atılıyordu, tek bir log yoktu.
     Artık `Confirm-Reboot` çıkış kodunu kontrol ediyor ve sırasıyla **shutdown.exe → WMI
     `Win32_OperatingSystem.Reboot` → `Restart-Computer`** deniyor; hangisinin gerçekten
     restart ilettiği log'a yazılıyor. Elle restart (pano düğmesi) de aynı yolu kullanıyor.
  3. 60 saniyelik geri sayımdaki kontrol `Invoke-WebRequest` ile yapılıyordu; internetsiz
     makinede DNS'te asılı kalınca döngü ölüyor, `shutdown.exe` hiç çağrılmıyordu. Artık
     sert zaman aşımlı soket kontrolü (`Test-InternetFast`) kullanılıyor ve geri sayım
     `try/catch` içinde — hata olursa bile restart yine yapılıyor.
- **Mesaj kutusu/uyarı birikimi (bir günde 276 `msg.exe` kutusu, 938 ALERT satırı).**
  06–08 arası saatte 144 uyarı, yani dakikada ~2 kutu. Sebebi iki taneydi:
  1. `Invoke-RebootIfNeeded` durumu başta okuyup sonra **eskisini geri yazıyordu**; arada
     `Send-UserNotification` `LastUserNotifyUtc`'yi kaydettiği için "4 saatte bir tekrar et"
     kısıtı her döngüde geri alınıyordu. Artık tüm durum yazmaları `Invoke-StateUpdate`
     (oku → değiştir → yaz) ile atomik.
  2. Aynı devre kesici durumu her döngüde hem ALERT satırı hem `msg.exe` üretiyordu. Artık
     durum değişmedikçe tekrar edilmiyor; **farklı** bir sorun çıkarsa anında bildiriliyor.
  Bildirim artık **konu bazlı**: aynı konu `NotifyRepeatHours` (varsayılan 4 saat) içinde bir kez,
  yeni konu hemen. Restart geri sayımındaki hatırlatma 20 saniyede birden değil **en fazla bir kez**.
- **Her dakika yeni tam döngü (eşzamanlı çalışma).** `-UserFallback` yolu — yani canlı yoklamanın
  tetiklediği yol — `Global\RemoteWatchdogCycle` kilidini hiç almıyordu. Bu yüzden
  `Test-CycleRunning` her zaman "çalışmıyor" diyor ve 1 dakikalık hızlı yoklama her seferinde
  yeni bir döngü açıyordu (günlükte 502 tetikleme, her dakika iki ayrı `dongu basladi`).
  Artık her iki yol da `Invoke-CycleLocked` ile aynı kilidi kullanıyor. Kesinti sürerken tam
  döngü tetiklemesine **geri sayım** eklendi (varsayılan 3 dk, kontrol aralığından türetilir);
  ilk tespit ve "bağlantı düzeldi" geçişi beklemez.
- **Ağ olay dinleyicisi kendini öldürüyordu:** tam döngüyü tetikledikten sonra döngüden `break`
  ile çıkıyor, görev zamanlayıcısının 1 dakika sonra yeniden başlatmasına kalıyordu.
  Artık durmaz, toparlanmayı dinlemeye devam eder.
- **"Restart değerlendirmesi bekliyor" eşiği (yeni `MinOutageMinutes`, varsayılan 10 dk).**
  Canlı yoklama dakikada bir çalıştığı için 2 saniyelik bir kopyalanma bile "1/1 başarısız
  döngü" sayılıp restart kararı üretiyordu. Artık restart kararı için kesintinin gerçekten
  bu kadar sürmüş olması gerekiyor; gerçek kesintilerde restart yine kesinlikle yapılır.
- **Panel tarafı:** aynı anons 5 dakika içinde ikinci kez konuşulmuyor; host tarafı da aynı
  metni 10 dakika içinde yeniden yazmıyor (dosya birikmesi engellendi).

### Eklenen
- `system-heartbeat.json`: yalnızca yetkili varsayılan (SYSTEM) döngü yazar; `-Check` ve
  kullanıcı yedeği yazmaz. Kullanıcı yedeği "SYSTEM görevi sağlıklı mı" kararını artık bu
  dosyadan veriyor.
  **Asıl hata şuydu:** eski kod `Get-ScheduledTask`'a bakıyordu, ama **yönetici olmayan bir
  oturum SYSTEM hesabına ait görevleri göremez** (çağrı boş döner). Sonuç: kullanıcı yedeği
  SYSTEM görevini "yok" sanıp her 5 dakikada devreye giriyordu → aynı anda iki tam döngü
  (`admin=True` ve `admin=False`), durum dosyası yarışı, çift sayım ve mesaj birikimi.
  `last-run.json`'ın `user` alanına bakmak da güvenilmez (herkes yazabilir).
- `-Status` artık SYSTEM görevinin varlığını `system-heartbeat.json` üzerinden bildiriyor.
  Önceden yönetici olmayan oturumdan `Get-ScheduledTask` boş döndüğü için **"zamanlanmış görev
  YOK (-Install çalıştır)"** gibi yanıltıcı bir sonuç veriyordu; görev çalışıyor olsa bile.
  Nabız zamanı ve "gerçek restart (24s) / bekleyen restart" bilgileri de eklendi.
- `last-run.json` → `state`: `reboots24h` (yalnızca **doğrulanmış** restartlar),
  `pendingRebootUtc`, `lastBootUtc`, `outageStartUtc`; `config.minOutageMinutes`.
- `tests\Verify-OutageLogic.ps1`: kesinti senaryosu için izole doğrulama (bütçe mutabakatı,
  sahte restart temizliği, bildirim kısıtı, geri sayım, anons birikimi, SYSTEM nabzı).
- `EkranMesaji` ayarı (BILDIRIM bölümü): `msg.exe` ekran mesaj kutusunu kapatır. Kapatınca
  sesli anons ve Telegram çalışmaya devam eder.

### Değişen — hız (tespit → karar → eylem en hızlı)
Amaç: gerçek ve çözülemeyen bir bağlantı sorununda **tespitten restart'a ~1 dakika**.

- **Varsayılanlar en hızlıya çekildi:** `RebootAfterFailedCycles` 3→**1**,
  `MinOutageMinutes` 10→**0** (bekleme yok), `RebootDelaySeconds` 60→**30**,
  `MinUptimeMinutes` 30→**3**, `RebootCooldownMinutes` 60→**2**,
  `HealthyMinutesToReset` 60→**30**, `OfficeSaveTimeoutSeconds` 120→**60**.
  Güvenlik sınırları bilerek kaldı: `MaxRestartsPerDay=3` (restart fırtınası olmaz),
  blip koruması (karar anında taze toparlanma kontrolü + geri sayım içinde iptal).
- **Tetiklenen döngü artık gerçekten çalışıyor.** `Start-FullCycle` `-UserFallback` ile
  başlatıyordu; o yol "SYSTEM sağlamsa hemen çık" demektir. Sonuç: canlı yoklama sorunu
  görüp tetikliyor, döngü hiçbir şey yapmadan çıkıyor ve karar bir sonraki 5 dakikalık
  SYSTEM döngüsüne kalıyordu (log: 12:21'de tetiklendi → karar 12:25'te). Artık varsayılan
  yol başlatılıyor (aynı kilit, çift çalışma yok); geri sayım damgası da yalnızca döngü
  gerçekten başladığında vuruluyor.
- **Canlı yoklama hafifledi.** `Get-FastProbeDecision` tam teşhis yapan `Get-NetworkHealth`
  yerine yeni `Get-QuickNetState` (3 kısa TCP denemesi, her biri 1,2 sn) kullanıyor;
  aşağı ağda üst üste binen zaman aşımları (~20 sn) yerine ~1,5 sn.
- **Boşa bekleyen problar kısıldı:** genel IP (`api.ipify.org`, 8 sn) yalnızca internet
  varken soruluyor; heartbeat zaman aşımı 15→5 sn; geri sayım öncesi taze kontrol 4→2 sn;
  hızlı yoklama geri sayımı (aynı anda birden çok döngüyü engelleyen fırtına koruması)
  3→**1 dk**.
- Ölçüm: tam döngü (sağlıklı ağ) ~9 sn; hızlı yoklama tespiti 2,5 sn (sağlıklı) / ~6 sn (ağ tamamen kapalı).
- **Eylem zincirindeki kalan beklemeler de kısıldı (ölçümle):** restart öncesi "internet geri
  geldi mi" taze kontrolü eskiden 3 hedef × 4 sn × 2 deneme ≈ **16 sn** yiyordu; artık tek
  hedef (1.1.1.1) × 1,2 sn × 2 deneme + 1 sn aralık ≈ **3,4 sn**. Geri sayım içindeki
  internet kontrolü de tek hedefe indirildi (her adımda uzun bekleme yok, döngü gerçekten
  30 sn sürüyor). Ağ olay dinleyicisindeki "IP/DHCP otursun" beklemesi 3 sn → **1 sn**.
  Canlı yoklamada IP açıksa isim çözümleme probları atlanıyor (duzelme tespiti hızlanır).

### Düzeltilen
- **Panel sürekli "Zamanlanmış görev: kurulu, şu an çalışmıyor" diyordu (yanlış alarm).**
  `Get-StatusTaskState` (lib\Contract.ps1) "çalışıyor" durumunu `Get-ScheduledTask` →
  `State -eq 'Running'` ile belirliyordu. Oysa görev **periyodik**: 5 dakikada bir tetiklenir,
  döngü ~10 saniye sürer ve arada `State` değeri **`Ready`** olur. Yani `Running` neredeyse hiç
  görünmediği için panel sürekli turuncu uyarı gösteriyordu — oysa her şey normal çalışıyordu.
  Artık ölçüt **veri tazeliği**: son kontrol, döngü aralığının ~2 katından (en az 3 dk) yeni
  ise görev "çalışıyor" sayılır. Görünen görevde ayrıca `Disabled` açık hata (kırmızı) olarak
  işaretlenir, iki saatlik bayat veri "takılmış olabilir" uyarısı verir. Metinler artık son
  kontrol zamanını da gösterir ("ÇALIŞIYOR (son kontrol 2 dk önce)").
- **Geri sayım anonsu, `RebootDelaySeconds` 60'dan farklı olduğunda sessizce kayboluyordu.**
  Önceden önbellekte yalnızca 60/30/10 sn klipleri vardı ve anahtar tam denk gelmezse
  (örn. eski 60 sn ayarı → `reboot60` dosyası bu makinede yok) panel metin eşleştirmeye
  düşüyor, internetsiz makinede edge-tts çalışmadığı ve Türkçe SAPI olmadığı için
  **anons hiç duyulmuyordu**. Artık: (1) host her süreyi en yakın hazır klibe yuvarlıyor
  (kısaya doğru: "45 sn" derken 60 demez, 30 der — makine sözden erken kapanır), (2) panel
  eksik anahtar için aile yedeğine düşüyor (`reboot60 → reboot30 → reboot10 → rebootplan`,
  `reminder`, `rebootcancel`, `netdown`). Böylece geri sayım anonsu **her sürede duyulur**.
- **`EkranMesaji` kapısı hiç çalışmıyordu (yazarken yakalandı):** `Get-Config` bir
  `OrderedDictionary` döner; onun anahtarları `.PSObject.Properties` ile görünmez
  (oradakiler adapter üyeleridir). Artık `IDictionary.Contains` ile bakılıyor.
  `Verify-OutageLogic` bu regresyonu yakaladı.
- **`Start-FullCycle` çift sayaç:** geri sayım damgası `Get-FastProbeDecision` içinde
  vuruluyordu; kilit meşgul olduğu için döngü başlatılamasa bile damga vuruluyor ve yoklama
  boşa bekliyordu. Damga artık başarılı başlatmada.

### Test
- `tests\Verify-OutageLogic.ps1` (yeni, 26 kontrol): bütçe mutabakatı, sahte restart temizliği,
  konu bazlı bildirim kısıtı, `MinOutageMinutes` eşiği, canlı yoklama geri sayımı, **yeni
  kesintinin geri sayımdan muaf olması**, anons birikim engeli, SYSTEM nabzı, restart anonsu
  kısıtı. Hepsi gerçek fonksiyon kodlarını izole bir durum dosyasıyla çalıştırır.
- `Test-All.ps1` artık kilit paylaşımını (`Invoke-CycleLocked`), canlı yoklama geri sayımını,
  restart bütçesi doğrulamasını ve `Confirm-Reboot` yedeğini de denetliyor. Düzeltilmiş bir
  test de vardı: 5. bölüm `-NoJson` kullanıyordu, bu değişken `Write-Status`'ı
  "hiç yazma" moda sokuyor; yani "tazelik" kontrolü aslında kendi ürettiği dosyayı değil,
  zamanlanmış görevin dosyasını ölçüyordu (5 dk'da bir değişirse test flak oluyordu).
## [1.2.3] - 2026-09-30

### Düzeltilen
- **Kısayollar hiçbir şey yapmıyordu:** masaüstü/Başlat menüsü kısayolları `Start-Panel.vbs`'i
  **`-Background`** ile çağırıyordu, yani "yalnızca tepside çalış" modunda açılıyordu. Panel
  zaten açıksa ikinci örnek mutex'te sessizce çıkıyor, "pencereyi göster" isteği hiç yazılmıyordu
  (`-Background` dalında bu istek bastırılır) → tıklamak hiçbir şeye yol açmıyordu. Panel kapalıysa
  da yalnızca tepsi simgesi beliriyor, pencere açılmıyordu. `Start-Panel.vbs` artık `show`
  argümanını destekliyor; kısayollar bu argümanla pencereyi öne getiriyor, zamanlanmış görev
  (`RemoteHostPanel`) ise parametresiz çalışmaya devam ediyor.
- **Panel zombie oluyordu (tray'de var ama panel gelmiyor):** pencere bir kez kapandıktan sonra
  WPF'te `Show()` her zaman *"Pencere kapatıldıktan sonra Show çağrılamaz"* hatası veriyordu; panel
  tepside görünmeye devam ediyor, pencere hiç açılmıyor, ayrıca `Local\RemoteWatchdogPanel` mutex'i
  kilitli kaldığı için **yeni hiçbir panel örneği açılamıyordu**. `Show-PanelWindow` yardımcısı eklendi
  (tüm gösterim çağrıları bundan geçiyor), `Closed` olayında `$script:WinClosed` işaretleniyor ve
  çıkış istenmemişse süreç kapanıyor — `RemoteHostPanel` görevi 1-2 dk içinde temiz bir paneli
  geri getiriyor.

### Eklenen
- **Kurulum sabit dizine taşındı:** `host\`/`ui\`/`lib\` (+`VERSION`) artık kurulumda
  **`C:\ProgramData\RemoteWatchdog\app`** altına kopyalanıyor (istemci tarafında
  `%LOCALAPPDATA%\RemoteWatchdog\app`) ve tüm zamanlanmış görevler, Run kaydı ve kısayollar
  **oradan** çalışıyor. Daha önce her şey kopyaladığın klasörden (ör. bir git deposundan) çalışıyordu;
  depo taşınsa/silinse görevler ve kısayollar bozuluyordu. Güncelleme için kurulum betiğini
  tekrar çalıştırmak yeterli; kopyalama öncesi açık panel kapatılıyor (dosya kilidi açılsın).
- `Install-Host.ps1 -DryRun` artık hedef kurulum dizinini de gösteriyor.

## [1.2.3] - 2026-09-29

### D├╝zeltilen
- **Tray'den ├ğ─▒k─▒┼ş yap─▒nca program bir daha a├ğ─▒lm─▒yordu (as─▒l hata):** *├ç─▒k─▒┼ş* men├╝s├╝nde
  `add_Closed` i├ğinde `[System.Windows.Threading.Dispatcher]::Shutdown()` ├ğa─şr─▒l─▒yordu; WPF'te
  b├Âyle bir **statik metot yok** (`Run`, `PushFrame`, `ExitAllFrames`, `Yield` var). ├ça─şr─▒
  `MethodNotFound` hatas─▒ verip `catch {}` ile yutuldu─şu i├ğin `Dispatcher.Run()` hi├ğ d├Ânm├╝yor,
  **PowerShell s├╝reci sonsuza kadar ayakta kal─▒yor ve `Local\RemoteWatchdogPanel` mutex'ini tutmaya
  devam ediyordu**. Sonu├ğ: k─▒sayola (ya da g├Âreve) tekrar bas─▒ld─▒─ş─▒nda yeni ├Ârnek mutex'te
  ├ğ─▒k─▒p sessizce kapan─▒yor, panel bir daha a├ğ─▒lm─▒yordu. Art─▒k `Dispatcher.InvokeShutdown()`
  (ger├ğekten var olan metot) ├ğa─şr─▒l─▒yor ÔåÆ `Run()` d├Ân├╝yor ÔåÆ betik bitiyor, s├╝re├ğ ├ğ─▒k─▒yor, mutex
  serbest kal─▒yor.
- **K─▒sayol paneli hi├ğ a├ğm─▒yordu (ikinci hata):** `Start-Panel.vbs` her zaman `-Background`
  g├Ânderiyordu; bu bayrak pencereyi gizli ba┼şlat─▒yor, ayr─▒ca ikinci ├Ârnek ├ğal─▒┼şan panelden
  "penceremi g├Âster" iste─şini **yazm─▒yordu**. Ba┼şlat─▒c─▒ya `show` arg├╝man─▒ eklendi: masa├╝st├╝ ve
  Ba┼şlat men├╝s├╝ k─▒sayollar─▒ `Start-Panel.vbs show` ile ├ğa─ş─▒r─▒p paneli g├Âr├╝n├╝r a├ğ─▒yor;
  zamanlanm─▒┼ş g├Ârev ise arg├╝mans─▒z ├ğa─şr─▒lmaya devam edip arka planda ├ğal─▒┼ş─▒yor.
- **├ç─▒km─▒┼ş panele "g├Âster" iste─şi hata veriyordu:** `ShowTimer` kapal─▒ pencereye `Show()`
  ├ğa─ş─▒r─▒p `YAKALANAMAYAN HATA ... Pencere kapat─▒ld─▒ktan sonra ... ├ğa─şr─▒lamaz` ile log'a d├╝┼ş├╝yordu.
  `add_Closed` i├ğinde `$script:WinClosed` bayra─ş─▒ tutuluyor; istek geldi─şinde pencere kapal─▒ysa
  ├Ârnek d├╝zg├╝n ┼şekilde kapat─▒l─▒yor. (`$script:Win.IsLoaded` kapanma sonras─▒ da `True` kald─▒─ş─▒ i├ğin
  g├╝venilir de─şil.)

### Test
- Regresyon testleri eklendi: `Test-All.ps1` art─▒k ge├ğersiz statik ├ğa─şr─▒n─▒n **kalmad─▒─ş─▒n─▒**,
  `InvokeShutdown` kullan─▒ld─▒─ş─▒n─▒, k─▒sayolun `show` arg├╝man─▒ verdi─şini ve ba┼şlat─▒c─▒n─▒n `show`
  modunda `-Background` g├Ândermedi─şini denetliyor; `Test-UI.ps1` ise ger├ğek bir WPF penceresiyle
  tray *├ç─▒k─▒┼ş* ak─▒┼ş─▒n─▒ ├ğal─▒┼şt─▒r─▒p `Dispatcher.Run()`'un ger├ğekten d├Ând├╝─ş├╝n├╝ do─şruluyor
  (eski kodda bu test k─▒rm─▒z─▒ya d├╝┼ş├╝yor, s├╝re├ğ ayakta kal─▒yor).

## [1.2.2] - 2026-09-29

### Eklenen
- **Anons kuyru─şu:** konu┼şma s├╝rerken gelen olay **sessizce kayboluyordu** ÔÇö motorlar me┼şgulde
  `false` d├Ân├╝yor, `Speak-Text` Windows SAPI'ye d├╝┼ş├╝yordu; bu makinede T├╝rk├ğe SAPI olmad─▒─ş─▒ i├ğin
  olay **hi├ğ seslenmeden kayboluyordu** (ayr─▒ca ses ├ğak─▒┼şmas─▒ riski). Art─▒k me┼şgulken olay
  kuyru─şa al─▒n─▒r, mevcut anons bitince **s─▒rayla** okunur (ayn─▒ metin tekille┼ştirilir, en fazla 8).
- **Restart anonsu kurtar─▒ld─▒:** restart paneli de ├Âld├╝rd├╝─ş├╝ i├ğin "Sistem yeniden ba┼şlat─▒l─▒yor"
  anonsu her zaman kayboluyordu ÔåÆ anons `pending-voice.json`'a yaz─▒l─▒yor, panel yeniden
  a├ğ─▒ld─▒─ş─▒nda `Speak-PendingVoice` ile konu┼şuluyor (30 dk'dan eskiyse okunmuyor).

### D├╝zeltilen
- **Panel dosyas─▒ BOM'suz kaydedilirse betik bozuluyor:** UTF-8 BOM olmayan dosyay─▒ Windows
  PowerShell 5.1 ANSI okuyor, T├╝rk├ğe karakterler bozulup t─▒rnak ka├ğ─▒yor (29 s├Âzdizimi hatas─▒).
  Regresyon testi eklendi (BOM varl─▒─ş─▒ denetleniyor).

## [1.2.1] - 2026-09-28

### Eklenen
- **Ba┼şlat men├╝s├╝ + masa├╝st├╝ k─▒sayolu:** `ui\Panel-Setup.ps1` (panel `-Install`/`-Uninstall` bunu
  ├ğa─ş─▒r─▒r) `RemoteWatchdog Kontrol Paneli.lnk` olu┼şturur. Hedef `wscript.exe` + `Start-Panel.vbs`
  oldu─şu i├ğin t─▒kland─▒─ş─▒nda **konsol penceresi a├ğ─▒lmaz**, panel do─şrudan a├ğ─▒l─▒r; proje simgesi kullan─▒l─▒r.
  Durum i├ğin `ui\Panel-Setup.ps1 -Action Status`.

### D├╝zeltilen
- **`-Install` panel a├ğ─▒kken hi├ğbir ┼şey yapm─▒yordu:** ikinci ├Ârnek mutex'te ├ğ─▒k─▒p `-Install`
  blo─şuna hi├ğ ula┼şm─▒yordu (bu y├╝zden k─▒sayol/g├Ârev kurulumu sessizce atlan─▒yordu) ÔåÆ kurulum
  i┼şlemleri mutex kontrol├╝n├╝n **├Ân├╝ne** al─▒nd─▒ ve ayr─▒ beti─şe ta┼ş─▒nd─▒.
- **G├╝nl├╝k art─▒k sadece ~1 g├╝n tutuyordu:** `Write-Log` her sat─▒rda dosyan─▒n tamam─▒n─▒ okuyup
  5000 sat─▒rda son 4000'e k─▒rp─▒yordu; 5 dakikal─▒k d├Âng├╝ + 1 dakikal─▒k yoklama g├╝nde ~4400 sat─▒r
  ├╝retiyor, yani tarih penceresi bir g├╝ne d├╝┼ş├╝yordu ÔåÆ **boyut tabanl─▒ rotasyon** (`LogDosyaMB`,
  varsay─▒lan 2 MB) ve **g├╝n bazl─▒ saklama** (`LogGunDays`, varsay─▒lan 30 g├╝n) eklendi
  (`log/host-watchdog-<tarih>.log` ar┼şivleri, eski olanlar otomatik silinir). Yan fayda: log yaz─▒m─▒
  art─▒k her sat─▒rda dosyay─▒ okumuyor.
- **Yoklama g├╝nl├╝─ş├╝:** "hizli yoklama ├ğal─▒┼ş─▒yor" sat─▒r─▒ 10 dakikada bir yerine **30 dakikada bir**
  yaz─▒l─▒yor (g├╝nl├╝k kirlili─şini azalt─▒r); yoklama yine **her 1 dakikada** ├ğal─▒┼ş─▒r.

## [1.2.0] - 2026-09-28

### Eklenen
- **Film efektleri (`SesEfektleri`, varsay─▒lan a├ğ─▒k):** ├Ânemli eylemler ve uyar─▒lar art─▒k **iki
  katmanl─▒** duyurulur ÔÇö ├Ânce haz─▒r bir efekt, hemen ard─▒ndan T├╝rk├ğe anons. Efektler depoda
  `ui/sounds/*.wav` olarak **haz─▒r** durur (├ğal─▒┼şma an─▒nda ├╝retim yok, panel ilk kullan─▒mda y├╝kleyip
  ├Ânbellekte tutar, olayla ses aras─▒nda bekleme olmaz).
  - **Ses tasar─▒m─▒ (`tools/SfxSynth.cs`, C# sintez motoru):** net **ve** keskin i├ğin 1.5 ms attack +
    4 ms parlak transient; parlakl─▒k i├ğin inharmonik metalik k─▒s─▒mlar (1 / 2 / 2.76 / 5.40 / 8.93) ve
    HP shimmer'l─▒ 5 tarafl─▒ damped reverb; ger├ğek├ğilik/g├╝├ğ i├ğin sub katman─▒ (55-330 Hz); k─▒rpmas─▒z
    tepe i├ğin tanh soft limiter + normalize + kenar fade.
  - **Sekiz efekt:** `alert` (3 darbeli metalik klakson), `warn` (iki notal─▒, detoneli uyar─▒),
    `ok` (parlak cam ping), `recover` (y├╝kselen shimmer + ├ğift ├ğ─▒nlama), `repair` (sonar taramas─▒),
    `reboot` (al├ğalan s├╝p├╝rme + sub + net blip), `online` (iki notal─▒ ├ğan + uzun kuyruk),
    `scan` (iki mikro blip).
  - **Olay e┼şlemesi:** ba─şlant─▒ koptu ÔåÆ `alert`, d├╝zeldi ÔåÆ `recover`, onar─▒m s├╝r├╝yor ÔåÆ `repair`,
    onar─▒m tamam/ba┼şar─▒s─▒z ÔåÆ `ok` / `warn`, reboot istendi/alg─▒land─▒ ÔåÆ `reboot`, yeniden ba┼şlat─▒ld─▒ ve
    kurulum ÔåÆ `online`, elle denetleme ba┼şlad─▒ ÔåÆ `scan`, denetleme sonucu ÔåÆ `ok` / `warn`.
  - **Ayarlar:** `SesEfektleri` (a├ğ/kapa) ve `SesEfektleriVolume` (0-100, 0 = efektler kapal─▒) ÔÇö
    Ayarlar ÔåÆ Bildirim'de otomatik g├Âr├╝n├╝r; tepsi men├╝s├╝ne *Ses efektleri (uzay)* anahtar─▒ eklendi
    (etiket a├ğ─▒k/kapal─▒ durumunu g├Âsterir). Tepsideki *Sessiz mod* anonsla birlikte efektleri de susturur.
  - **Dayan─▒kl─▒l─▒k:** paket eksik veya ses ayg─▒t─▒ yoksa Windows sistem sesine d├╝┼ş├╝l├╝r ve durum
    `panel.log`'a yaz─▒l─▒r; `Get-SfxPath` yol enjeksiyonunu temizler (yaln─▒zca dosya ad─▒ kullan─▒l─▒r).
- **Yerel T├╝rk├ğe konu┼şma motoru (Piper TTS):** insan sesi anonslar─▒ art─▒k **internetsiz** ├ğal─▒┼ş─▒yor.
  `edge-tts` do─şal T├╝rk├ğe kad─▒n sesi (`tr-TR-EmelNeural`) sunuyordu ama Microsoft ├╝cretsiz ucu
  kapatt─▒─ş─▒ i├ğin art─▒k **HTTP 403** d├Ând├╝r├╝yor ve panel susuyordu ÔåÆ `tools/Install-Voice.ps1` ile
  **Piper TTS + do─şal T├╝rk├ğe kad─▒n modeli** (`tr_TR-dfki-medium`, ~82 MB) kuruluyor
  (`%LOCALAPPDATA%\RemoteWatchdog\voice`). ├ûncelik s─▒ras─▒: **Piper (yerel) ÔåÆ edge-tts (bulut) ÔåÆ
  Windows T├╝rk├ğe SAPI ÔåÆ susar**. Panel a├ğ─▒l─▒┼şta motoru `panel.log`'a yazar.
- **Do─şal KADIN T├╝rk├ğe ses (edge-tts `tr-TR-EmelNeural`) geri geldi:** edge-tts 7.x, a─ş i┼şlemleri
  i├ğin `aiodns` kullan─▒yor ve bu k├╝t├╝phane Windows'ta yaln─▒zca `SelectorEventLoop` ile ├ğal─▒┼ş─▒yor;
  s├╝re├ğ ses ├╝retmeden `"aiodns needs a SelectorEventLoop on Windows"` hatas─▒yla d├╝┼ş├╝yordu (eski
  s├╝r├╝mlerde ise DRM token olmad─▒─ş─▒ i├ğin **HTTP 403** geliyordu) ÔåÆ `tools/edge_tts_win.py`
  sarmalay─▒c─▒s─▒ eklendi (politikay─▒ `edge_tts` import edilmeden **├Ânce** ayarl─▒yor), panel bu
  sarmalay─▒c─▒y─▒ tercih ediyor, `-m edge_tts` yaln─▒zca yedek yol. ├ûncelik s─▒ras─▒:
  **edge-tts (do─şal kad─▒n) ÔåÆ Piper (yerel erkek, internetsiz) ÔåÆ T├╝rk├ğe SAPI ÔåÆ susar**.
  Do─şrulanan T├╝rk├ğe model kar┼ş─▒la┼şt─▒rmas─▒: Piper `tr_TR-dfki` / `fahrettin` / `fettah`,
  `mms-tts-tur` ve `speecht5-tts-turkish` modellerinin t├╝m├╝ **erkek**; do─şal kad─▒n T├╝rk├ğe i├ğin
  edge-tts tek se├ğenek.
- **Kapat─▒lan ses tekrar ├ğal─▒yordu:** film efektleri (wav) ve insan sesi art─▒k **├ğal─▒┼şma an─▒nda
  sabitlenen** anahtarlarla kontrol ediliyor (`$script:SfxOn` / `$script:VoiceOn`): tepsi anahtar─▒yla
  kapat─▒lan katman, `config.json`'─▒ kim yazarsa yazs─▒n o oturum boyunca susuyor. Ayr─▒ca *Sessiz mod*
  etiketi **"Sessiz mod (t├╝m sesler)"** oldu ve balon metni art─▒k "bu katman kapand─▒, di─şeri a├ğ─▒k"
  diyor ÔÇö ├Ânceki durumda "film efektlerini kapatt─▒m ama ses geliyor" ya┼şan─▒yordu ├ğ├╝nk├╝ duyulan ses
  **insan sesiydi** (ayr─▒ anahtar, istenen davran─▒┼ş) ama ayr─▒m net de─şildi.
- **Ayr─▒ ses anahtarlar─▒:** *wav* (film efektleri, `SesEfektleri`) ile **insan sesi**
  (T├╝rk├ğe anons, `SesliBildirim`) art─▒k **ba─ş─▒ms─▒z** a├ğ─▒l─▒p kapan─▒yor. Tepsi men├╝s├╝nde
  *Sesli anons (insan sesi)* ve *Film efektleri (wav)* girdileri (etiketler a├ğ─▒k/kapal─▒ durumunu
  g├Âsterir) ve ikisini birden denetleyen *Ses testi* eklendi. *Sessiz mod* ikisini birlikte susturur.
- **T├╝rk├ğe telaffuz d├╝zeltmesi:** anons metinleri **ASCII** yaz─▒lm─▒┼şt─▒ (`Baglanti duzeldi`),
  seslendirici de T├╝rk├ğe harfleri duyamay─▒p ─░ngilizce okuyordu (kullan─▒c─▒ bildirimi) ÔåÆ t├╝m anons
  metinleri ger├ğek T├╝rk├ğe karakterlerle ve noktalama ile yeniden yaz─▒ld─▒ (`Ba─şlant─▒ d├╝zeldi.`,
  `A─ş onar─▒l─▒yor.`, `Onar─▒m tamamland─▒.`ÔÇĞ). `last-run.json`'dan ASCII gelen kontrol adlar─▒ i├ğin
  `ConvertTo-TtsText` + `$script:TtsFix` s├Âzl├╝─ş├╝ eklendi (`Internet erisimi` ÔåÆ `─░nternet eri┼şimi`);
  genel ASCIIÔåÆdiakritik ├ğevirisi bilin├ğli olarak **yap─▒lm─▒yor** (`─▒nternet` hatas─▒n─▒ ├Ânlemek i├ğin).
- **Yeniden ├╝retim arac─▒ (`tools/New-SoundPack.ps1`):** paketi yeniden ├╝retir (`-List`, `-Verify`);
  dosyalar ├╝retilmi┼ş olarak depoda durdu─şu i├ğin kurulum makinelerinde ek ba─ş─▒ml─▒l─▒k gerekmez.
- **Testler:** Test-All'a 21 yeni kontrol (8 efektin varl─▒─ş─▒/ge├ğerli WAV ba┼şl─▒─ş─▒/boyutu, panel
  API'si ve ├Ân y├╝kleme, olay e┼şlemesi, efekt ad─▒ Ôåö paket tutarl─▒l─▒─ş─▒, ayar tan─▒mlar─▒, host/panel
  varsay─▒lanlar─▒, konu┼şma motoru ├Ânceli─şi); Test-UI'a 12 yeni kontrol (paket b├╝t├╝nl├╝─ş├╝,
  `Get-SfxPath` yol g├╝venli─şi, ses seviyesi, oynatma, ├Ânbellek temizli─şi, bayrak okuma ve Piper ile
  u├ğtan uca T├╝rk├ğe ses ├╝retimi).

### D├╝zeltilen
- **Bozuk konu┼şma motoru sessizce yutuyordu:** edge-tts ├╝retemedi─şinde (├Âr. 403) panel 25 saniye
  bekleyip hi├ğbir ┼şey s├Âylemeden ge├ğiyordu; art─▒k ├╝retici s├╝reci izleniyor, dosya bitince
  **k─▒smi ses oynat─▒lm─▒yor** ve dosya hi├ğ olu┼şmazsa T├╝rk├ğe SAPI'ya d├╝┼ş├╝l├╝yor (yoksa en az─▒ndan
  `panel.log`'a net uyar─▒ d├╝┼ş├╝yor).
- **Her anons sayac─▒ yeni i┼şleyici ekliyordu:** `Add_Tick` her `Speak-*` ├ğa─şr─▒s─▒nda tekrar
  ekleniyordu (n anons = n i┼şleyici, aray├╝z yava┼şl─▒yor) ÔåÆ `Start-SpeechPoller` ile tek kez kuruluyor.
- **├£retici s├╝reci kapat─▒lm─▒yordu:** iptal/├ğ─▒k─▒┼şta ge├ğici `cmd`/`python` s├╝reci ├ğal─▒┼şmaya devam
  ediyordu ÔåÆ `Stop-Speech` art─▒k s├╝reci de sonland─▒r─▒yor.
- **Panel her a├ğ─▒l─▒┼şta sessiz modda a├ğ─▒l─▒yordu (ses hi├ğ ├ğ─▒km─▒yordu):** tepsi kayd─▒ndaki bayrak metin
  olarak saklan─▒yor (`'0'` / `'1'`), kod ise do─şrudan `[bool]` ile ├ğeviriyordu; PowerShell'de bo┼ş
  olmayan her metin `TRUE` oldu─şu i├ğin "sessiz de─şil" (`'0'`) bile sessiz say─▒l─▒yordu. ├ûzellikle
  SelfTest sessiz mod anahtar─▒n─▒ bir kez de─şi┼ştirdikten sonra **her yeniden ba┼şlatmada** sesler
  (anons + efektler) susturuluyordu ÔåÆ `Get-FlagBool` ile g├╝venli okuma eklendi (Test-UI'da 4 kontrol).
- **Eski panel s├╝reci g├╝ncellemeyi engelliyordu:** ├ğal─▒┼şan eski s├╝r├╝m, yeni ba┼şlatma iste─şini al─▒p
  kapal─▒ pencereye `Show()` ├ğa─ş─▒rd─▒─ş─▒ i├ğin "Pencere kapat─▒ld─▒ktan sonra Show ├ğa─şr─▒lamaz" hatas─▒
  veriyordu ÔåÆ g├╝ncellemeden ├Ânce ├ğal─▒┼şan paneli durdurup yeniden ba┼şlatmak yeterli.
- **Ses ├ğalmayan makinede sessiz kalma:** efekt dosyas─▒ bulunamazsa veya `MediaPlayer` ba┼şar─▒s─▒z
  olursa art─▒k sessiz kal─▒nm─▒yor, sistem sesine d├╝┼ş├╝l├╝yor (uyar─▒ bir kez log'a yaz─▒l─▒r).

## [1.1.0] - 2026-09-28

### Eklenen
- **Renkli g├╝nl├╝k:** g├╝nl├╝k sat─▒rlar─▒ kurala g├Âre renkleniyor ÔÇö **ye┼şil** = stabil durum (`TAMAM`),
  **k─▒rm─▒z─▒** = hata/sorun (`WARN`, `ALERT`, `SORUN`), **mavi** = bilgilendirme (`INFO`, `ATLANDI`).
  Panel g├╝nl├╝k sekmesi `RichTextBox`'a ge├ğti (sat─▒r bazl─▒ renk), konsol ├ğ─▒kt─▒s─▒ da ayn─▒ kural─▒ kullan─▒yor.
- **H─▒zl─▒ yoklama izi:** yoklama art─▒k "├ğal─▒┼ş─▒yor" sat─▒r─▒n─▒ 10 dakikada bir yazar ve
  `probe-state.json` dosyas─▒n─▒ her ko┼şuda g├╝nceller (yoklaman─▒n ├ğal─▒┼şt─▒─ş─▒ g├Âr├╝lebilir olsun diye).
- **D├╝zeltilen**
- **probe-state hi├ğ yaz─▒lm─▒yordu:** `Save-ProbeState` i├ğinde PowerShell 5.1'in `$beat`/`$Beat`
  isim ├ğak─▒┼şmas─▒ (`-not $Beat` yerel `$beat` de─şi┼şkenine ba─şlan─▒yor) hatay─▒ tetikliyor, `catch`
  yutuyordu ÔåÆ de─şi┼şken ad─▒ ayr─▒ld─▒, yazma 3 kez yeniden deneniyor ve hata art─▒k g├╝nl├╝─şe yaz─▒l─▒yor.
- **Kullan─▒c─▒-seviyesi yedek g├Ârev (`RemoteHostWatchdogUser`):** kurumsal y├Ânetim SYSTEM
  g├Ârevlerini silerse izleme durmas─▒n diye `-Install` art─▒k kullan─▒c─▒ g├Ârevini de kaydediyor.
  G├Ârev `-UserFallback` ile ├ğal─▒┼ş─▒r: SYSTEM sa─şlam + veri tazeyken sessiz ├ğ─▒kar, yoksa tam
  d├Âng├╝y├╝ ├╝stlenir (`-Uninstall` kald─▒r─▒r, `-Status` durumunu g├Âsterir).
- **H─▒zl─▒ yoklama (`RemoteHostFastProbe`, `-FastProbe`):** 5 dakikal─▒k d├Âng├╝ sorunu ge├ğ fark
  ediyordu ÔåÆ her 1 dakikada hafif a─ş yoklamas─▒; sorun g├Âr├╝rse tam d├Âng├╝y├╝ hemen tetikler.
  D├╝zelmeyi de yakalar: ├Ânceki durum k├Ât├╝yse (veya son rapor hatal─▒ysa) ba─şlant─▒ geri geldi─şinde
  tam d├Âng├╝ tetiklenir, "ba─şlant─▒ d├╝zeldi" kayd─▒ ve anonsu olu┼şur.
- **Panel canl─▒ yenileme:** ba─şlant─▒lar ancak kapat─▒p a├ğ─▒nca g├╝ncelleniyordu ÔåÆ `last-run.json`
  damga yoklamas─▒ (1 sn) ile yaz─▒ld─▒─ş─▒ anda yenileniyor (20 sn saya├ğ yedek). Not: ilk denemede
  `FileSystemWatcher` kullan─▒ld─▒, ancak olaylar─▒ runspace'siz havuz ba┼şl─▒─ş─▒nda ├ğal─▒┼şt─▒r─▒p s├╝reci
  ├ğ├Âkertiyordu (`PSInvalidOperation`) ÔåÆ yoklamaya d├Ân├╝ld├╝.
- **Ayarlar hemen ge├ğerli:** kaydetme art─▒k watchdog g├Ârevini tetikliyor; kesinti s─▒ras─▒nda
  de─şi┼ştirilen ayarlar s─▒radaki d├Âng├╝y├╝ beklemiyor.
- **Sesli bildirim (`SesliBildirim`, varsay─▒lan a├ğ─▒k):** t├╝m ├Ânemli olaylarda k─▒sa T├╝rk├ğe anons
  (sorun / d├╝zeldi / onar─▒l─▒yor / tamamland─▒ / tekrar ba┼şlat─▒l─▒yor / ba┼şlat─▒ld─▒). Ses **do─şal kad─▒n**
  T├╝rk├ğe (`edge-tts` `tr-TR-EmelNeural`); kurulu de─şilse Windows'un T├╝rk├ğe sesi (`Tolga`), T├╝rk├ğe
  ses hi├ğ yoksa ─░ngilizce okumaz (susar). Panels├╝recinde ├ğal─▒┼ş─▒r (SYSTEM oturumunda ses ├ğ─▒kmaz);
  sessiz modda susar. Ayarlar ÔåÆ Bildirim'den kapat─▒labilir, `SesliBildirimEdge` do─şal sesi kapat─▒r.
- **Wire-UI korumas─▒:** pencere olu┼şmadan ├ğa─şr─▒l─▒rsa kriptik hata yerine net ┼şekilde atlan─▒r
  (test ortam─▒nda g├Âr├╝len `Dispatcher` null hatas─▒).
- **Tepsi men├╝s├╝nden panel a├ğ─▒l─▒┼ş─▒:** "Paneli ba┼şlat" `-WindowStyle Normal` ile ├ğal─▒┼şt─▒r─▒yordu;
  ekranda ikinci bir komut penceresi a├ğ─▒l─▒yor, kapat─▒l─▒nca program da kapan─▒yordu ÔåÆ gizli ba┼şlatma.
- **Siyah/mavi ekranlar (gidi-gelen konsol):** Windows Terminal varsay─▒lan terminal oldu─şunda
  g├Ârev konsolunu Terminal bar─▒nd─▒r─▒yor, `-WindowStyle Hidden` yok say─▒l─▒yordu ÔåÆ kullan─▒c─▒
  g├Ârevleri art─▒k `wscript.exe` + yeni `host/Start-Hidden.vbs` ile ba┼şlat─▒l─▒yor (pencere hi├ğ olu┼şmuyor).
- **Panel erken kapanmas─▒:** `ShutdownMode=OnExplicitShutdown` yap─▒ld─▒; son pencere kapansa bile
  tepsi ve izleme ayakta kal─▒r. Ayr─▒ca aray├╝zdispatcher hata yakalay─▒c─▒s─▒ `add_UnhandledException`
  ile kuruluyor (`.UnhandledException.Add(...)` PowerShell'de null d├Ân├╝yordu ve iz b─▒rakm─▒yordu).

### D├╝zeltilen
- **IP eri┼şimi probu tek adrese bak─▒yordu:** kurumsal duvarda `1.1.1.1` kapal─▒ysa sat─▒r s├╝rekli
  k─▒rm─▒z─▒ kal─▒yordu ÔåÆ `9.9.9.9 ÔåÆ 1.1.1.1 ÔåÆ 8.8.8.8` yedek listesi; panel aktif IP'yi g├Âsterir
  (`iphost` metri─şi).
- **TIME_WAIT sayac─▒ port numaras─▒n─▒ okuyordu:** `netstat -s` ├ğ─▒kt─▒s─▒ndaki ilk TIME_WAIT sat─▒r─▒n─▒n
  portu (├Ârn. 58631) saya├ğ san─▒l─▒yordu ÔåÆ `netstat -ano` sat─▒r say─▒m─▒na ge├ğildi (host + te┼şhis raporu).
- **"A─ş adapt├Âr├╝/link olay─▒" boot kay─▒tlar─▒n─▒ say─▒yordu:** System `27/32` ID'leri ├ğekirdek-boot
  kaynakl─▒yd─▒ ÔåÆ `Kernel-Boot` sa─şlay─▒c─▒s─▒ filtrelendi.
- **Te┼şhis raporu DNS hatas─▒ hep 0 g├Âsteriyordu:** kanal ad─▒ yanl─▒┼şt─▒
  (`DNS-Client Events/Operational` ÔåÆ `DNS-Client/Operational`).
- **IP eri┼şimi etiketi yaz─▒m hatas─▒:** `(DNS ba─ş─▒─ş─▒ de─şil)` ÔåÆ `(DNS bagimsiz, dogrudan IP)`.

## [1.0.1] - 2026-09-28

### D├╝zeltilen
- **Panel hi├ğ ba┼şlam─▒yordu (tepsi simgesi ├ğ─▒km─▒yordu):** a├ğ─▒l─▒┼şta `$w.add_DispatcherUnhandledException(...)`
  ├ğa─şr─▒l─▒yordu; bu metot `Window` s─▒n─▒f─▒nda yoktur (dispatcher'a aittir). Hata non-terminating oldu─şu
  i├ğin ak─▒┼ş devam ediyor, ancak ikinci hata (`$script:Win` null) y├╝z├╝nden s├╝re├ğ kapan─▒yordu. Do─şru yol
  kullan─▒ld─▒: `$script:Win.Dispatcher.UnhandledException.Add(...)` ve dosya sonundaki **m├╝kerrer** kay─▒t
  kald─▒r─▒ld─▒. Ayr─▒ca ayn─▒ dosyada ikinci bir hata yakalay─▒c─▒ daha vard─▒; tek merkez├« kay─▒t b─▒rak─▒ld─▒.
  (Bu hata `v1.0.0`'da mevcuttu; `Test-UI`/`Test-All` ye┼şil oldu─şu i├ğin g├Âzden ka├ğm─▒┼şt─▒ ÔÇö art─▒k
  `-SelfTest` ├ğ─▒kt─▒s─▒nda `add_Dispatcher` hatas─▒ aran─▒r.)

## [1.0.0] - 2026-09-28

─░lk kamuya a├ğ─▒k s├╝r├╝m. Windows + PowerShell 5.1, harici mod├╝l yok.

### Eklenen
- **─░ki katmanl─▒ watchdog**: uzak makinede (SYSTEM) kontrol + kademeli onar─▒m + restart politikas─▒;
  kendi bilgisayar─▒nda istemci (TCP yoklama, kopma alarm─▒, RDP/taray─▒c─▒ otomatik a├ğma).
- **Kademeli a─ş onar─▒m─▒**: DNS ├Ânbelle─şi ÔåÆ DHCP yenileme ÔåÆ adapt├Âr/s├╝r├╝c├╝ ÔåÆ servis ÔåÆ
  winsock/IP s─▒f─▒rlama. Her kademeden sonra tekrar ├Âl├ğer, sa─şl─▒kl─▒ olunca durur.
- **Canl─▒ onar─▒m penceresi**: "A─ş─▒ onar" d├╝─şmesi ayr─▒ pencere a├ğar, sistem g├╝nl├╝─ş├╝nden sat─▒rlar
  700 ms'de bir akar (`[WARN] elle ag onarimi basladiÔÇĞ` ÔåÆ `kademe N uygulandi` ÔåÆ `ag onarimi bitti`).
- **UAC'siz onar─▒m**: istek `repair-request.json`'a yaz─▒l─▒r; `RemoteHostRepair` (tetikleyicisiz) ve
  `RemoteHostRepairWatch` (60 sn) g├Ârevleri SYSTEM'de uygular. G├Ârev yoksa g├Ârevi elle de
  ba┼şlat─▒labilir (`-RepairNetwork -Rung N`).
- **WPF kontrol paneli** (tek dosya, XAML): Durum / Bekleyen i┼şler / Ayarlar / G├╝nl├╝k sekmeleri,
  sistem tepsisi simgesi (renkli), ├╝stte canl─▒ saya├ğ, koyu tema, proje simgesi (`ui/app.ico`).
- **Restart politikas─▒**: blackout penceresi (varsay─▒lan 18:00ÔåÆ08:00 + Cmt/Paz), tatil modu,
  devre kesici (`MaxRestartsPerDay`, `RebootCooldownMinutes`, `MinUptimeMinutes`).
- **Veri kayb─▒ korumas─▒**: `Protect-OpenDocuments.ps1` kaydedilmemi┼ş Word/Excel belgelerini
  periyodik kaydeder, AutoRecover'─▒ k─▒salt─▒r, reboot'u kaydedilmemi┼ş belge varsa iptal eder.
- **Alarm**: Telegram (durum de─şi┼şimi + tekrarl─▒ uyar─▒), healthchecks.io heartbeat, te┼şhis raporu
  (`host/Collect-Diagnostics.ps1`, 14 g├╝nl├╝k olay g├╝nl├╝─ş├╝ analizi).
- **Veri s├Âzle┼şmesi**: `lib/Contract.ps1` ÔÇö `last-run.json` sadece `Write-Status`/`Read-Status` ile
  yaz─▒l─▒r/okunur, `schemaVersion` damgal─▒, geriye d├Ân├╝k normalizasyonlu.
- **Ortak katman**: `lib/Common.ps1` (JSON/TCP/g├╝n d├Ân├╝┼ş├╝m├╝), `lib/Settings.ps1` (65 ayar + 11 balon).
- **Testler**: `tests/Test-All.ps1` (118 kontrol) ve `tests/Test-UI.ps1` (23 kontrol, WPF'yi
  pencere g├Âstermeden kurup ger├ğek `Click` g├Ânderir). CI: `.github/workflows/tests.yml`
  (push/PR'da Windows runner'da ├ğal─▒┼ş─▒r).
- **D─▒┼ş izleyici**: `.github/workflows/machine-health.yml` saatte 2 kez GitHub'dan makineyi yoklar,
  yan─▒t vermezse Telegram'a uyar─▒r (makine kapal─▒/internetsiz durumunun tek yakalay─▒c─▒s─▒).
- **Katk─▒ altyap─▒s─▒**: MIT lisans─▒, `CONTRIBUTING.md` / `README.en.md` / `SECURITY.md`,
  issue + PR ┼şablonlar─▒, s├╝r├╝m tutarl─▒l─▒k testi.

### D├╝zeltilen (bu s├╝r├╝mde ├ğ├Âz├╝len ├Ânemli hatalar)
- `-RepairNetwork` iste─şi 5 dakika bekliyordu: ana g├Ârev `MultipleInstances=IgnoreNew` oldu─şu i├ğin
  ├ğal─▒┼ş─▒rken ba┼şlat─▒lam─▒yordu, ayr─▒ca normal kullan─▒c─▒ SYSTEM g├Ârevini ad─▒yla ba┼şlatam─▒yordu ÔåÆ
  on-demand + 60 sn'lik izleyici g├Ârevleri eklendi.
- 60 sn'lik izleyici `last-run.json`'u kontrol listesi olmadan yaz─▒yordu (panelde "kontrol yok") ÔåÆ
  `Write-RepairStatusPatch` ile mevcut `checks`/`state`/`config` korunuyor.
- Canl─▒ onar─▒m penceresi **X ile kapat─▒l─▒nca** bir sonraki t─▒klamada a├ğ─▒lm─▒yordu (d├╝─şme
  "Onar─▒l─▒yor..."'da kal─▒yordu) ÔåÆ pencere canl─▒l─▒─ş─▒ kontrol├╝ + `Closed` olay─▒.
- `Complete-ManualCheck` i┼şlem d├╝─şmesi listesini bo┼şalt─▒yordu ÔåÆ aksiyon ├ğubu─şu renk/eri┼şim
  g├╝ncellemesini kaybediyordu.
- `Test-UI.ps1` `Get-Json`'u y├╝klemiyordu ÔåÆ bir kontrol sessizce hi├ğ ├ğal─▒┼şm─▒yordu; art─▒k iki suite
  de sonunda "tan─▒ms─▒z komut" taramas─▒ yap─▒yor.
- A├ğ─▒l─▒┼şta 25 sn sonra otomatik ba┼şlayan 11 balonluk yard─▒m turu kald─▒r─▒ld─▒; balon bildirimleri
  varsay─▒lan kapal─▒.
- Ba─şlant─▒lar sayfas─▒nda ├╝st bar + saya├ğ y├╝z├╝nden dikey kayd─▒rma ├ğubu─şu (217 px) ÔåÆ 0 px.
- Pencere simgesi PowerShell amblemi iken proje simgesine (`ui/app.ico`) ├ğevrildi.

[1.1.0]: https://github.com/ferden51/remote-watchdog/releases/tag/v1.1.0
[1.0.1]: https://github.com/ferden51/remote-watchdog/releases/tag/v1.0.1
[1.0.0]: https://github.com/ferden51/remote-watchdog/releases/tag/v1.0.0
