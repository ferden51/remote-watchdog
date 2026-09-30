# Changelog

Bu dosya sürüm bazlı değişiklikleri tutar. Sürüm numarası depodaki `VERSION` dosyasındadır;
panel ve host betikleri bu dosyayı okur (`-Version` ile sorgulanabilir). Sürümleme
[semantic versioning](https://semver.org/lang/tr/) uyumludur.

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

## [1.2.3] - 2026-09-29

### Düzeltilen
- **Tray'den çıkış yapınca program bir daha açılmıyordu (asıl hata):** *Çıkış* menüsünde
  `add_Closed` içinde `[System.Windows.Threading.Dispatcher]::Shutdown()` çağrılıyordu; WPF'te
  böyle bir **statik metot yok** (`Run`, `PushFrame`, `ExitAllFrames`, `Yield` var). Çağrı
  `MethodNotFound` hatası verip `catch {}` ile yutulduğu için `Dispatcher.Run()` hiç dönmüyor,
  **PowerShell süreci sonsuza kadar ayakta kalıyor ve `Local\RemoteWatchdogPanel` mutex'ini tutmaya
  devam ediyordu**. Sonuç: kısayola (ya da göreve) tekrar basıldığında yeni örnek mutex'te
  çıkıp sessizce kapanıyor, panel bir daha açılmıyordu. Artık `Dispatcher.InvokeShutdown()`
  (gerçekten var olan metot) çağrılıyor → `Run()` dönüyor → betik bitiyor, süreç çıkıyor, mutex
  serbest kalıyor.
- **Kısayol paneli hiç açmıyordu (ikinci hata):** `Start-Panel.vbs` her zaman `-Background`
  gönderiyordu; bu bayrak pencereyi gizli başlatıyor, ayrıca ikinci örnek çalışan panelden
  "penceremi göster" isteğini **yazmıyordu**. Başlatıcıya `show` argümanı eklendi: masaüstü ve
  Başlat menüsü kısayolları `Start-Panel.vbs show` ile çağırıp paneli görünür açıyor;
  zamanlanmış görev ise argümansız çağrılmaya devam edip arka planda çalışıyor.
- **Çıkmış panele "göster" isteği hata veriyordu:** `ShowTimer` kapalı pencereye `Show()`
  çağırıp `YAKALANAMAYAN HATA ... Pencere kapatıldıktan sonra ... çağrılamaz` ile log'a düşüyordu.
  `add_Closed` içinde `$script:WinClosed` bayrağı tutuluyor; istek geldiğinde pencere kapalıysa
  örnek düzgün şekilde kapatılıyor. (`$script:Win.IsLoaded` kapanma sonrası da `True` kaldığı için
  güvenilir değil.)

### Test
- Regresyon testleri eklendi: `Test-All.ps1` artık geçersiz statik çağrının **kalmadığını**,
  `InvokeShutdown` kullanıldığını, kısayolun `show` argümanı verdiğini ve başlatıcının `show`
  modunda `-Background` göndermediğini denetliyor; `Test-UI.ps1` ise gerçek bir WPF penceresiyle
  tray *Çıkış* akışını çalıştırıp `Dispatcher.Run()`'un gerçekten döndüğünü doğruluyor
  (eski kodda bu test kırmızıya düşüyor, süreç ayakta kalıyor).

## [1.2.2] - 2026-09-29

### Eklenen
- **Anons kuyruğu:** konuşma sürerken gelen olay **sessizce kayboluyordu** — motorlar meşgulde
  `false` dönüyor, `Speak-Text` Windows SAPI'ye düşüyordu; bu makinede Türkçe SAPI olmadığı için
  olay **hiç seslenmeden kayboluyordu** (ayrıca ses çakışması riski). Artık meşgulken olay
  kuyruğa alınır, mevcut anons bitince **sırayla** okunur (aynı metin tekilleştirilir, en fazla 8).
- **Restart anonsu kurtarıldı:** restart paneli de öldürdüğü için "Sistem yeniden başlatılıyor"
  anonsu her zaman kayboluyordu → anons `pending-voice.json`'a yazılıyor, panel yeniden
  açıldığında `Speak-PendingVoice` ile konuşuluyor (30 dk'dan eskiyse okunmuyor).

### Düzeltilen
- **Panel dosyası BOM'suz kaydedilirse betik bozuluyor:** UTF-8 BOM olmayan dosyayı Windows
  PowerShell 5.1 ANSI okuyor, Türkçe karakterler bozulup tırnak kaçıyor (29 sözdizimi hatası).
  Regresyon testi eklendi (BOM varlığı denetleniyor).

## [1.2.1] - 2026-09-28

### Eklenen
- **Başlat menüsü + masaüstü kısayolu:** `ui\Panel-Setup.ps1` (panel `-Install`/`-Uninstall` bunu
  çağırır) `RemoteWatchdog Kontrol Paneli.lnk` oluşturur. Hedef `wscript.exe` + `Start-Panel.vbs`
  olduğu için tıklandığında **konsol penceresi açılmaz**, panel doğrudan açılır; proje simgesi kullanılır.
  Durum için `ui\Panel-Setup.ps1 -Action Status`.

### Düzeltilen
- **`-Install` panel açıkken hiçbir şey yapmıyordu:** ikinci örnek mutex'te çıkıp `-Install`
  bloğuna hiç ulaşmıyordu (bu yüzden kısayol/görev kurulumu sessizce atlanıyordu) → kurulum
  işlemleri mutex kontrolünün **önüne** alındı ve ayrı betiğe taşındı.
- **Günlük artık sadece ~1 gün tutuyordu:** `Write-Log` her satırda dosyanın tamamını okuyup
  5000 satırda son 4000'e kırpıyordu; 5 dakikalık döngü + 1 dakikalık yoklama günde ~4400 satır
  üretiyor, yani tarih penceresi bir güne düşüyordu → **boyut tabanlı rotasyon** (`LogDosyaMB`,
  varsayılan 2 MB) ve **gün bazlı saklama** (`LogGunDays`, varsayılan 30 gün) eklendi
  (`log/host-watchdog-<tarih>.log` arşivleri, eski olanlar otomatik silinir). Yan fayda: log yazımı
  artık her satırda dosyayı okumuyor.
- **Yoklama günlüğü:** "hizli yoklama çalışıyor" satırı 10 dakikada bir yerine **30 dakikada bir**
  yazılıyor (günlük kirliliğini azaltır); yoklama yine **her 1 dakikada** çalışır.

## [1.2.0] - 2026-09-28

### Eklenen
- **Film efektleri (`SesEfektleri`, varsayılan açık):** önemli eylemler ve uyarılar artık **iki
  katmanlı** duyurulur — önce hazır bir efekt, hemen ardından Türkçe anons. Efektler depoda
  `ui/sounds/*.wav` olarak **hazır** durur (çalışma anında üretim yok, panel ilk kullanımda yükleyip
  önbellekte tutar, olayla ses arasında bekleme olmaz).
  - **Ses tasarımı (`tools/SfxSynth.cs`, C# sintez motoru):** net **ve** keskin için 1.5 ms attack +
    4 ms parlak transient; parlaklık için inharmonik metalik kısımlar (1 / 2 / 2.76 / 5.40 / 8.93) ve
    HP shimmer'lı 5 taraflı damped reverb; gerçekçilik/güç için sub katmanı (55-330 Hz); kırpmasız
    tepe için tanh soft limiter + normalize + kenar fade.
  - **Sekiz efekt:** `alert` (3 darbeli metalik klakson), `warn` (iki notalı, detoneli uyarı),
    `ok` (parlak cam ping), `recover` (yükselen shimmer + çift çınlama), `repair` (sonar taraması),
    `reboot` (alçalan süpürme + sub + net blip), `online` (iki notalı çan + uzun kuyruk),
    `scan` (iki mikro blip).
  - **Olay eşlemesi:** bağlantı koptu → `alert`, düzeldi → `recover`, onarım sürüyor → `repair`,
    onarım tamam/başarısız → `ok` / `warn`, reboot istendi/algılandı → `reboot`, yeniden başlatıldı ve
    kurulum → `online`, elle denetleme başladı → `scan`, denetleme sonucu → `ok` / `warn`.
  - **Ayarlar:** `SesEfektleri` (aç/kapa) ve `SesEfektleriVolume` (0-100, 0 = efektler kapalı) —
    Ayarlar → Bildirim'de otomatik görünür; tepsi menüsüne *Ses efektleri (uzay)* anahtarı eklendi
    (etiket açık/kapalı durumunu gösterir). Tepsideki *Sessiz mod* anonsla birlikte efektleri de susturur.
  - **Dayanıklılık:** paket eksik veya ses aygıtı yoksa Windows sistem sesine düşülür ve durum
    `panel.log`'a yazılır; `Get-SfxPath` yol enjeksiyonunu temizler (yalnızca dosya adı kullanılır).
- **Yerel Türkçe konuşma motoru (Piper TTS):** insan sesi anonsları artık **internetsiz** çalışıyor.
  `edge-tts` doğal Türkçe kadın sesi (`tr-TR-EmelNeural`) sunuyordu ama Microsoft ücretsiz ucu
  kapattığı için artık **HTTP 403** döndürüyor ve panel susuyordu → `tools/Install-Voice.ps1` ile
  **Piper TTS + doğal Türkçe kadın modeli** (`tr_TR-dfki-medium`, ~82 MB) kuruluyor
  (`%LOCALAPPDATA%\RemoteWatchdog\voice`). Öncelik sırası: **Piper (yerel) → edge-tts (bulut) →
  Windows Türkçe SAPI → susar**. Panel açılışta motoru `panel.log`'a yazar.
- **Doğal KADIN Türkçe ses (edge-tts `tr-TR-EmelNeural`) geri geldi:** edge-tts 7.x, ağ işlemleri
  için `aiodns` kullanıyor ve bu kütüphane Windows'ta yalnızca `SelectorEventLoop` ile çalışıyor;
  süreç ses üretmeden `"aiodns needs a SelectorEventLoop on Windows"` hatasıyla düşüyordu (eski
  sürümlerde ise DRM token olmadığı için **HTTP 403** geliyordu) → `tools/edge_tts_win.py`
  sarmalayıcısı eklendi (politikayı `edge_tts` import edilmeden **önce** ayarlıyor), panel bu
  sarmalayıcıyı tercih ediyor, `-m edge_tts` yalnızca yedek yol. Öncelik sırası:
  **edge-tts (doğal kadın) → Piper (yerel erkek, internetsiz) → Türkçe SAPI → susar**.
  Doğrulanan Türkçe model karşılaştırması: Piper `tr_TR-dfki` / `fahrettin` / `fettah`,
  `mms-tts-tur` ve `speecht5-tts-turkish` modellerinin tümü **erkek**; doğal kadın Türkçe için
  edge-tts tek seçenek.
- **Kapatılan ses tekrar çalıyordu:** film efektleri (wav) ve insan sesi artık **çalışma anında
  sabitlenen** anahtarlarla kontrol ediliyor (`$script:SfxOn` / `$script:VoiceOn`): tepsi anahtarıyla
  kapatılan katman, `config.json`'ı kim yazarsa yazsın o oturum boyunca susuyor. Ayrıca *Sessiz mod*
  etiketi **"Sessiz mod (tüm sesler)"** oldu ve balon metni artık "bu katman kapandı, diğeri açık"
  diyor — önceki durumda "film efektlerini kapattım ama ses geliyor" yaşanıyordu çünkü duyulan ses
  **insan sesiydi** (ayrı anahtar, istenen davranış) ama ayrım net değildi.
- **Ayrı ses anahtarları:** *wav* (film efektleri, `SesEfektleri`) ile **insan sesi**
  (Türkçe anons, `SesliBildirim`) artık **bağımsız** açılıp kapanıyor. Tepsi menüsünde
  *Sesli anons (insan sesi)* ve *Film efektleri (wav)* girdileri (etiketler açık/kapalı durumunu
  gösterir) ve ikisini birden denetleyen *Ses testi* eklendi. *Sessiz mod* ikisini birlikte susturur.
- **Türkçe telaffuz düzeltmesi:** anons metinleri **ASCII** yazılmıştı (`Baglanti duzeldi`),
  seslendirici de Türkçe harfleri duyamayıp İngilizce okuyordu (kullanıcı bildirimi) → tüm anons
  metinleri gerçek Türkçe karakterlerle ve noktalama ile yeniden yazıldı (`Bağlantı düzeldi.`,
  `Ağ onarılıyor.`, `Onarım tamamlandı.`…). `last-run.json`'dan ASCII gelen kontrol adları için
  `ConvertTo-TtsText` + `$script:TtsFix` sözlüğü eklendi (`Internet erisimi` → `İnternet erişimi`);
  genel ASCII→diakritik çevirisi bilinçli olarak **yapılmıyor** (`ınternet` hatasını önlemek için).
- **Yeniden üretim aracı (`tools/New-SoundPack.ps1`):** paketi yeniden üretir (`-List`, `-Verify`);
  dosyalar üretilmiş olarak depoda durduğu için kurulum makinelerinde ek bağımlılık gerekmez.
- **Testler:** Test-All'a 21 yeni kontrol (8 efektin varlığı/geçerli WAV başlığı/boyutu, panel
  API'si ve ön yükleme, olay eşlemesi, efekt adı ↔ paket tutarlılığı, ayar tanımları, host/panel
  varsayılanları, konuşma motoru önceliği); Test-UI'a 12 yeni kontrol (paket bütünlüğü,
  `Get-SfxPath` yol güvenliği, ses seviyesi, oynatma, önbellek temizliği, bayrak okuma ve Piper ile
  uçtan uca Türkçe ses üretimi).

### Düzeltilen
- **Bozuk konuşma motoru sessizce yutuyordu:** edge-tts üretemediğinde (ör. 403) panel 25 saniye
  bekleyip hiçbir şey söylemeden geçiyordu; artık üretici süreci izleniyor, dosya bitince
  **kısmi ses oynatılmıyor** ve dosya hiç oluşmazsa Türkçe SAPI'ya düşülüyor (yoksa en azından
  `panel.log`'a net uyarı düşüyor).
- **Her anons sayacı yeni işleyici ekliyordu:** `Add_Tick` her `Speak-*` çağrısında tekrar
  ekleniyordu (n anons = n işleyici, arayüz yavaşlıyor) → `Start-SpeechPoller` ile tek kez kuruluyor.
- **Üretici süreci kapatılmıyordu:** iptal/çıkışta geçici `cmd`/`python` süreci çalışmaya devam
  ediyordu → `Stop-Speech` artık süreci de sonlandırıyor.
- **Panel her açılışta sessiz modda açılıyordu (ses hiç çıkmıyordu):** tepsi kaydındaki bayrak metin
  olarak saklanıyor (`'0'` / `'1'`), kod ise doğrudan `[bool]` ile çeviriyordu; PowerShell'de boş
  olmayan her metin `TRUE` olduğu için "sessiz değil" (`'0'`) bile sessiz sayılıyordu. Özellikle
  SelfTest sessiz mod anahtarını bir kez değiştirdikten sonra **her yeniden başlatmada** sesler
  (anons + efektler) susturuluyordu → `Get-FlagBool` ile güvenli okuma eklendi (Test-UI'da 4 kontrol).
- **Eski panel süreci güncellemeyi engelliyordu:** çalışan eski sürüm, yeni başlatma isteğini alıp
  kapalı pencereye `Show()` çağırdığı için "Pencere kapatıldıktan sonra Show çağrılamaz" hatası
  veriyordu → güncellemeden önce çalışan paneli durdurup yeniden başlatmak yeterli.
- **Ses çalmayan makinede sessiz kalma:** efekt dosyası bulunamazsa veya `MediaPlayer` başarısız
  olursa artık sessiz kalınmıyor, sistem sesine düşülüyor (uyarı bir kez log'a yazılır).

## [1.1.0] - 2026-09-28

### Eklenen
- **Renkli günlük:** günlük satırları kurala göre renkleniyor — **yeşil** = stabil durum (`TAMAM`),
  **kırmızı** = hata/sorun (`WARN`, `ALERT`, `SORUN`), **mavi** = bilgilendirme (`INFO`, `ATLANDI`).
  Panel günlük sekmesi `RichTextBox`'a geçti (satır bazlı renk), konsol çıktısı da aynı kuralı kullanıyor.
- **Hızlı yoklama izi:** yoklama artık "çalışıyor" satırını 10 dakikada bir yazar ve
  `probe-state.json` dosyasını her koşuda günceller (yoklamanın çalıştığı görülebilir olsun diye).
- **Düzeltilen**
- **probe-state hiç yazılmıyordu:** `Save-ProbeState` içinde PowerShell 5.1'in `$beat`/`$Beat`
  isim çakışması (`-not $Beat` yerel `$beat` değişkenine bağlanıyor) hatayı tetikliyor, `catch`
  yutuyordu → değişken adı ayrıldı, yazma 3 kez yeniden deneniyor ve hata artık günlüğe yazılıyor.
- **Kullanıcı-seviyesi yedek görev (`RemoteHostWatchdogUser`):** kurumsal yönetim SYSTEM
  görevlerini silerse izleme durmasın diye `-Install` artık kullanıcı görevini de kaydediyor.
  Görev `-UserFallback` ile çalışır: SYSTEM sağlam + veri tazeyken sessiz çıkar, yoksa tam
  döngüyü üstlenir (`-Uninstall` kaldırır, `-Status` durumunu gösterir).
- **Hızlı yoklama (`RemoteHostFastProbe`, `-FastProbe`):** 5 dakikalık döngü sorunu geç fark
  ediyordu → her 1 dakikada hafif ağ yoklaması; sorun görürse tam döngüyü hemen tetikler.
  Düzelmeyi de yakalar: önceki durum kötüyse (veya son rapor hatalıysa) bağlantı geri geldiğinde
  tam döngü tetiklenir, "bağlantı düzeldi" kaydı ve anonsu oluşur.
- **Panel canlı yenileme:** bağlantılar ancak kapatıp açınca güncelleniyordu → `last-run.json`
  damga yoklaması (1 sn) ile yazıldığı anda yenileniyor (20 sn sayaç yedek). Not: ilk denemede
  `FileSystemWatcher` kullanıldı, ancak olayları runspace'siz havuz başlığında çalıştırıp süreci
  çökertiyordu (`PSInvalidOperation`) → yoklamaya dönüldü.
- **Ayarlar hemen geçerli:** kaydetme artık watchdog görevini tetikliyor; kesinti sırasında
  değiştirilen ayarlar sıradaki döngüyü beklemiyor.
- **Sesli bildirim (`SesliBildirim`, varsayılan açık):** tüm önemli olaylarda kısa Türkçe anons
  (sorun / düzeldi / onarılıyor / tamamlandı / tekrar başlatılıyor / başlatıldı). Ses **doğal kadın**
  Türkçe (`edge-tts` `tr-TR-EmelNeural`); kurulu değilse Windows'un Türkçe sesi (`Tolga`), Türkçe
  ses hiç yoksa İngilizce okumaz (susar). Panelsürecinde çalışır (SYSTEM oturumunda ses çıkmaz);
  sessiz modda susar. Ayarlar → Bildirim'den kapatılabilir, `SesliBildirimEdge` doğal sesi kapatır.
- **Wire-UI koruması:** pencere oluşmadan çağrılırsa kriptik hata yerine net şekilde atlanır
  (test ortamında görülen `Dispatcher` null hatası).
- **Tepsi menüsünden panel açılışı:** "Paneli başlat" `-WindowStyle Normal` ile çalıştırıyordu;
  ekranda ikinci bir komut penceresi açılıyor, kapatılınca program da kapanıyordu → gizli başlatma.
- **Siyah/mavi ekranlar (gidi-gelen konsol):** Windows Terminal varsayılan terminal olduğunda
  görev konsolunu Terminal barındırıyor, `-WindowStyle Hidden` yok sayılıyordu → kullanıcı
  görevleri artık `wscript.exe` + yeni `host/Start-Hidden.vbs` ile başlatılıyor (pencere hiç oluşmuyor).
- **Panel erken kapanması:** `ShutdownMode=OnExplicitShutdown` yapıldı; son pencere kapansa bile
  tepsi ve izleme ayakta kalır. Ayrıca arayüzdispatcher hata yakalayıcısı `add_UnhandledException`
  ile kuruluyor (`.UnhandledException.Add(...)` PowerShell'de null dönüyordu ve iz bırakmıyordu).

### Düzeltilen
- **IP erişimi probu tek adrese bakıyordu:** kurumsal duvarda `1.1.1.1` kapalıysa satır sürekli
  kırmızı kalıyordu → `9.9.9.9 → 1.1.1.1 → 8.8.8.8` yedek listesi; panel aktif IP'yi gösterir
  (`iphost` metriği).
- **TIME_WAIT sayacı port numarasını okuyordu:** `netstat -s` çıktısındaki ilk TIME_WAIT satırının
  portu (örn. 58631) sayaç sanılıyordu → `netstat -ano` satır sayımına geçildi (host + teşhis raporu).
- **"Ağ adaptörü/link olayı" boot kayıtlarını sayıyordu:** System `27/32` ID'leri çekirdek-boot
  kaynaklıydı → `Kernel-Boot` sağlayıcısı filtrelendi.
- **Teşhis raporu DNS hatası hep 0 gösteriyordu:** kanal adı yanlıştı
  (`DNS-Client Events/Operational` → `DNS-Client/Operational`).
- **IP erişimi etiketi yazım hatası:** `(DNS bağığı değil)` → `(DNS bagimsiz, dogrudan IP)`.

## [1.0.1] - 2026-09-28

### Düzeltilen
- **Panel hiç başlamıyordu (tepsi simgesi çıkmıyordu):** açılışta `$w.add_DispatcherUnhandledException(...)`
  çağrılıyordu; bu metot `Window` sınıfında yoktur (dispatcher'a aittir). Hata non-terminating olduğu
  için akış devam ediyor, ancak ikinci hata (`$script:Win` null) yüzünden süreç kapanıyordu. Doğru yol
  kullanıldı: `$script:Win.Dispatcher.UnhandledException.Add(...)` ve dosya sonundaki **mükerrer** kayıt
  kaldırıldı. Ayrıca aynı dosyada ikinci bir hata yakalayıcı daha vardı; tek merkezî kayıt bırakıldı.
  (Bu hata `v1.0.0`'da mevcuttu; `Test-UI`/`Test-All` yeşil olduğu için gözden kaçmıştı — artık
  `-SelfTest` çıktısında `add_Dispatcher` hatası aranır.)

## [1.0.0] - 2026-09-28

İlk kamuya açık sürüm. Windows + PowerShell 5.1, harici modül yok.

### Eklenen
- **İki katmanlı watchdog**: uzak makinede (SYSTEM) kontrol + kademeli onarım + restart politikası;
  kendi bilgisayarında istemci (TCP yoklama, kopma alarmı, RDP/tarayıcı otomatik açma).
- **Kademeli ağ onarımı**: DNS önbelleği → DHCP yenileme → adaptör/sürücü → servis →
  winsock/IP sıfırlama. Her kademeden sonra tekrar ölçer, sağlıklı olunca durur.
- **Canlı onarım penceresi**: "Ağı onar" düğmesi ayrı pencere açar, sistem günlüğünden satırlar
  700 ms'de bir akar (`[WARN] elle ag onarimi basladi…` → `kademe N uygulandi` → `ag onarimi bitti`).
- **UAC'siz onarım**: istek `repair-request.json`'a yazılır; `RemoteHostRepair` (tetikleyicisiz) ve
  `RemoteHostRepairWatch` (60 sn) görevleri SYSTEM'de uygular. Görev yoksa görevi elle de
  başlatılabilir (`-RepairNetwork -Rung N`).
- **WPF kontrol paneli** (tek dosya, XAML): Durum / Bekleyen işler / Ayarlar / Günlük sekmeleri,
  sistem tepsisi simgesi (renkli), üstte canlı sayaç, koyu tema, proje simgesi (`ui/app.ico`).
- **Restart politikası**: blackout penceresi (varsayılan 18:00→08:00 + Cmt/Paz), tatil modu,
  devre kesici (`MaxRestartsPerDay`, `RebootCooldownMinutes`, `MinUptimeMinutes`).
- **Veri kaybı koruması**: `Protect-OpenDocuments.ps1` kaydedilmemiş Word/Excel belgelerini
  periyodik kaydeder, AutoRecover'ı kısaltır, reboot'u kaydedilmemiş belge varsa iptal eder.
- **Alarm**: Telegram (durum değişimi + tekrarlı uyarı), healthchecks.io heartbeat, teşhis raporu
  (`host/Collect-Diagnostics.ps1`, 14 günlük olay günlüğü analizi).
- **Veri sözleşmesi**: `lib/Contract.ps1` — `last-run.json` sadece `Write-Status`/`Read-Status` ile
  yazılır/okunur, `schemaVersion` damgalı, geriye dönük normalizasyonlu.
- **Ortak katman**: `lib/Common.ps1` (JSON/TCP/gün dönüşümü), `lib/Settings.ps1` (65 ayar + 11 balon).
- **Testler**: `tests/Test-All.ps1` (118 kontrol) ve `tests/Test-UI.ps1` (23 kontrol, WPF'yi
  pencere göstermeden kurup gerçek `Click` gönderir). CI: `.github/workflows/tests.yml`
  (push/PR'da Windows runner'da çalışır).
- **Dış izleyici**: `.github/workflows/machine-health.yml` saatte 2 kez GitHub'dan makineyi yoklar,
  yanıt vermezse Telegram'a uyarır (makine kapalı/internetsiz durumunun tek yakalayıcısı).
- **Katkı altyapısı**: MIT lisansı, `CONTRIBUTING.md` / `README.en.md` / `SECURITY.md`,
  issue + PR şablonları, sürüm tutarlılık testi.

### Düzeltilen (bu sürümde çözülen önemli hatalar)
- `-RepairNetwork` isteği 5 dakika bekliyordu: ana görev `MultipleInstances=IgnoreNew` olduğu için
  çalışırken başlatılamıyordu, ayrıca normal kullanıcı SYSTEM görevini adıyla başlatamıyordu →
  on-demand + 60 sn'lik izleyici görevleri eklendi.
- 60 sn'lik izleyici `last-run.json`'u kontrol listesi olmadan yazıyordu (panelde "kontrol yok") →
  `Write-RepairStatusPatch` ile mevcut `checks`/`state`/`config` korunuyor.
- Canlı onarım penceresi **X ile kapatılınca** bir sonraki tıklamada açılmıyordu (düğme
  "Onarılıyor..."'da kalıyordu) → pencere canlılığı kontrolü + `Closed` olayı.
- `Complete-ManualCheck` işlem düğmesi listesini boşaltıyordu → aksiyon çubuğu renk/erişim
  güncellemesini kaybediyordu.
- `Test-UI.ps1` `Get-Json`'u yüklemiyordu → bir kontrol sessizce hiç çalışmıyordu; artık iki suite
  de sonunda "tanımsız komut" taraması yapıyor.
- Açılışta 25 sn sonra otomatik başlayan 11 balonluk yardım turu kaldırıldı; balon bildirimleri
  varsayılan kapalı.
- Bağlantılar sayfasında üst bar + sayaç yüzünden dikey kaydırma çubuğu (217 px) → 0 px.
- Pencere simgesi PowerShell amblemi iken proje simgesine (`ui/app.ico`) çevrildi.

[1.1.0]: https://github.com/ferden51/remote-watchdog/releases/tag/v1.1.0
[1.0.1]: https://github.com/ferden51/remote-watchdog/releases/tag/v1.0.1
[1.0.0]: https://github.com/ferden51/remote-watchdog/releases/tag/v1.0.0
