# Güvenlik bildirimleri / Security policy

## Desteklenen sürümler

| Sürüm | Durum |
|---|---|
| `main` (son commit) | Destekleniyor |

## Nasıl bildirim yapılır

Bu araç **SYSTEM yetkisiyle** çalışır ve ağ/servis komutları yürütür. Bir güvenlik açığı bulduğunuzu
düşünüyorsanız lütfen **public issue açmayın**. Bunun yerine:

1. Depo üzerinden **GitHub Private Vulnerability Reporting** kullanın (`Security` -> `Report a
   vulnerability`), veya
2. Depo sayfasındaki **Security advisories** bölümünden bildirim gönderin.

Yanıt süresi: 7 gün içinde ilk değerlendirme. Düzeltme yayınlandıktan sonra advisory olarak
duyurulur; gönderene teşekkür adıyla (veya isterse anonim) kredilendirilir.

## Kapsam dışı (kusur değil, özellik gereği)

- `Enable-ConsoleAutoLogon.ps1` parolayı registry'de düz metin saklar (Winlogon `DefaultPassword`).
  Bu kasıtlıdır ve betiğin başında uyarı olarak yazılıdır; ev/ofis gibi güvenli sayılan ağlarda
  kullanılmalıdır.
- `RemoteHostWatchdog.ps1` "blackout" saatlerinde uzaktan yeniden başlatma yapabilir. Bu, izleme
  felsefesinin bir parçasıdır ve `RestartPolicy = never` ile kapatılabilir.
- Ağ onarım kademeleri (DNS temizleme, DHCP yenileme, adaptör kapat/aç, winsock/IP sıfırlama)
  bağlantıyı kısa süreli keser. Beklenen davranıştır.

## Katkıcılar için

Depoya gizli değer girmeyin: `config.json`, `*-state.json`, `last-run.json` zaten `.gitignore`
tarafından yok sayılır. Bir PR'da token/chat id/heartbeat adresi görürseniz lütfen yazmayın ve
bize bildirin.
