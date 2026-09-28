# Changelog

Bu dosya sürüm bazlı değişiklikleri tutar. Sürüm numarası depodaki `VERSION` dosyasındadır;
panel ve host betikleri bu dosyayı okur (`-Version` ile sorgulanabilir). Sürümleme
[semantic versioning](https://semver.org/lang/tr/) uyumludur.

## [Yayınlanmadı]

### Eklenen
- **Kullanıcı-seviyesi yedek görev (`RemoteHostWatchdogUser`):** kurumsal yönetim SYSTEM
  görevlerini silerse izleme durmasın diye `-Install` artık kullanıcı görevini de kaydediyor.
  Görev `-UserFallback` ile çalışır: SYSTEM sağlam + veri tazeyken sessiz çıkar, yoksa tam
  döngüyü üstlenir (`-Uninstall` kaldırır, `-Status` durumunu gösterir).

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

[1.0.1]: https://github.com/ferden51/remote-watchdog/releases/tag/v1.0.1
[1.0.0]: https://github.com/ferden51/remote-watchdog/releases/tag/v1.0.0
