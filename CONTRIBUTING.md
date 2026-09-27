# Katkıda bulunma / Contributing

Teşekkürler! Bu proje bir uzak bilgisayarı "kendisi gibi bırakılmış bir sunucu" gibi çalıştırmak için
var: bağlantı koparsa ne olduğunu bulur, kademeli olarak onarır, gerekirse yeniden başlatır ve
kendisinden haberdar eder.

- Türkçe okuyorsanız bu dosya, İngilizce için [CONTRIBUTING.en.md](CONTRIBUTING.en.md).

## Hızlı başlangıç (katkı öncesi)

```powershell
# 1) Tüm testler (beklenen: Gecti: 118 | Kaldi: 0)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1

# 2) Arayüz testleri (WPF, STA gerekir; beklenen: Gecti: 23 | Kaldi: 0)
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Test-UI.ps1

# 3) Paneli açmadan arayüzü kur + PNG üret + kapat (kendi makinenizde de çalışır)
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\ui\RemoteWatchdogPanel.ps1 -SelfTest -PreviewPath "$env:TEMP\panel.png"
```

`Test-All.ps1` **gerçek sistem durumunu okur** (`C:\ProgramData\RemoteWatchdog\last-run.json`).
Kendi makinenizde çalıştırmak sorun değildir; sadece yazma yapmaz. GitHub Actions'ta aynı dosyalar
temiz bir runner'da çalışır, çünkü iş akışı önce `ProgramData\RemoteWatchdog` klasörünü hazırlar.

## Proje yapısı

| Yol | Ne yapar |
|---|---|
| `host/RemoteHostWatchdog.ps1` | Uzak makine (SYSTEM): kontrol, kademeli ağ onarımı, servis, CRD/RDP, alarm, restart politikası |
| `client/RemoteClientWatchdog.ps1` | Bu makine (istemci): dışarıya "nabız" gönderir, paneli izler |
| `ui/RemoteWatchdogPanel.ps1` | WPF kontrol paneli + sistem tepsisi simgesi (tek dosya, modüler fonksiyonlar) |
| `lib/Common.ps1` | Paylaşılan yardımcılar (JSON, TCP ölçümü, gün dönüşümü) |
| `lib/Contract.ps1` | host/client <-> panel arasındaki **tek** veri sözleşmesi (`schemaVersion`) |
| `lib/Settings.ps1` | Ayar tanımları (`$script:Defs`) ve yardım balonu metinleri |
| `install/*.ps1` | Yönetici kurulum yardımcıları |
| `tests/*.ps1` | Regresyon paketleri |

## Kod kuralları

1. **`.ps1` dosyaları UTF-8 BOM ile kaydedilir.** Windows PowerShell 5.1 BOM'suz dosyada Türkçe
   karakterleri bozar. Yeni dosya eklerken BOM'u koruyun.
2. **Yorum satırı eklemekten kaçının.** Kod kendini anlatır; yalnızca neden'in açıklanmadığı yerlerde
   (PowerShell tuzakları, politika kararları) tek satır yorum istenir.
3. **Veri sözleşmesini tek yerde tutun:** `last-run.json` alanlarını `lib/Contract.ps1` üzerinden
   yazın. Panel veya host kendi JSON'unu elle yazmaz; geriye dönük uyum için `Read-Status`
   normalizasyonunu kullanın.
4. **Yeni ayar eklerken:** `lib/Settings.ps1` içindeki `$script:Defs` tablosuna satır ekleyin
   (`@{ Sec='Onarim'; Key='FixXyz'; Title='Metin'; Type='bool|int|text|enum|days|lines|csv|datetime' }`).
   Host varsayılanı `Get-Config`, panel okuyucu `Get-HostConfig` tarafında yaşar.
5. **PowerShell tuzaklarından kaçının:**
   - Bir fonksiyon içinde `GetNewClosure()` ile yaratılan scriptblock, `$script:X` yazarken geçici
     kapsama yazar; nesne/sözlük referansı yakalamak gerekir (`$store = $script:EnumSelect` deseni).
   - WPF `Button` için `MouseLeftButtonUp` değil `add_Click` kullanın.
   - Olay işleyicileri `$w` yerine `$script:Win` üzerinden erişsin.
   - `New-Object System.Windows.GridLength('Auto')` yerine
     `[System.Windows.GridLength]::new([System.Windows.GridUnitType]::Auto)`.
   - UI'yi bloklamayın: uzun işler `DispatcherTimer` + olay tabanlı akışla yapılır, `Start-Sleep` ile
     beklenmez (aksi halde WPF çizilmez).
6. **Kod yorumları ve hata mesajları Türkçe kalabilir**; kullanıcıya görünen metinler Türkçedir.
   İngilizce dokümantasyon `README.en.md` / `CONTRIBUTING.en.md` içindedir.
7. Test eklerken: `tests/Test-All.ps1` içine `Ok 'ad: aciklama' (<koşul>)` kalıbıyla ekleyin; testler
   kendi makinenizin durumuna bağlı olmamalı, koşulu açıkça yazmalıdır.

## Pull request akışı

1. Konu (issue) açın ya da mevcut bir konuya bağlanın — kapsam dışı değişiklikler için önce konuşun.
2. Konu/feature dalı açın (`git switch -c feat/konu`).
3. Yukarıdaki üç komutu da çalıştırıp çıktıyı PR açıklamasına yapıştırın.
4. **Davranış değiştiriyorsanız** `README.md` (ve `README.en.md`) ilgili bölümünü güncelleyin.
5. PR açıklamasında: neyi değiştirdiğiniz, neden, hangi testlerin çalıştığı, geriye dönük uyum
   (varsa `schemaVersion` etkisi).

## Güvenlik

Bu araç SYSTEM yetkisiyle ve ağ komutları çalıştırır (servis yeniden başlatma, adaptör kapat/aç,
winsock/IP sıfırlama, restart). Güvenlik açığı bildirmek için [SECURITY.md](SECURITY.md).
Katkı gönderirken lütfen gizli değer (Telegram token, heartbeat adresi, parola, kullanıcı adı)
eklemeyin; `config.json` depo tarafından yok sayılır.
