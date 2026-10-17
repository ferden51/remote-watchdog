# remote-watchdog

> English / Türkçe
>
> [README.en.md](README.en.md) · License: [MIT](LICENSE) · Contributions: [CONTRIBUTING.md](CONTRIBUTING.md) / [CONTRIBUTING.en.md](CONTRIBUTING.en.md)

RemoteWatchdog is a self-healing Windows watchdog for a remote PC. It detects connectivity and service problems, repairs the network in stages, reboots only when necessary, and keeps you informed via Telegram and healthchecks.

RemoteWatchdog, uzaktaki bir Windows PC için kendi kendini iyileştiren bir watchdog'dur. Bağlantı ve servis sorunlarını tespit eder, ağ sorunlarını aşamalı şekilde onarır, sadece gerekli olduğunda yeniden başlatır ve Telegram/healthchecks üzerinden sizi bilgilendirir.

## Overview / Genel bakış

### English

The project has two parts:

1. Host side: runs on the remote machine as SYSTEM and checks local Windows services, RDP/CRD, clock sync, network health, sleep/hibernate settings, and reboot policy.
2. Client side: runs on your own PC and monitors whether the remote machine is reachable over TCP. If the link is down, it alerts you and can launch the remote desktop or browser automatically.

A tray panel exposes status, logs, actions, and repair flows, while the scripts are intentionally dependency-free and work with Windows PowerShell 5.1.

### Türkçe

Proje iki parçadan oluşur:

1. Host tarafı: uzaktaki makinada SYSTEM olarak çalışır ve yerel Windows servisleri, RDP/CRD, saat senkronu, ağ sağlığı, uyku/hibernasyon ayarları ve yeniden başlatma politikasını kontrol eder.
2. Client tarafı: kendi bilgisayarınızda çalışır ve uzaktaki makinenin TCP üzerinden erişilebilir olup olmadığını izler. Bağlantı koparsa sizi uyarır ve otomatik olarak uzak masaüstü veya tarayıcı açabilir.

Tepsi paneli durum, günlük, işlemler ve onarım akışlarını gösterir; betikler kasıtlı olarak bağımlılık içermeden Windows PowerShell 5.1 ile çalışacak şekilde tasarlanmıştır.

## What it does / Neler yapar

| Module / Modül | English summary / Türkçe özeti |
| --- | --- |
| `host/RemoteHostWatchdog.ps1` | Checks CRD/RDP/network/clock/power, repairs issues step-by-step, configures services, sends heartbeats and Telegram alerts, and reboots only when justified. / CRD/RDP/ağ/saat/güç kontrollerini yapar, sorunları aşamalı onarır, servisleri ayarlar, heartbeat ve Telegram uyarıları gönderir, gerekliyse yeniden başlatır. |
| `host/Protect-OpenDocuments.ps1` | Auto-saves open Word/Excel documents and prevents a reboot from trampling unsaved work. / Açık Word/Excel belgelerini otomatik kaydeder ve yeniden başlatmanın kaydedilmemiş çalışma kaybına neden olmasını engeller. |
| `host/Collect-Diagnostics.ps1` | Collects logs and network diagnostics, without modifying the system. / Sistemi değiştirmeden günlük ve ağ teşhis verilerini toplar. |
| `client/RemoteClientWatchdog.ps1` | Tests reachability to the target, alerts on disconnect, and can open RDP/browser. / Hedefe erişimi test eder, kopma halinde uyarır ve RDP/tarayıcı açabilir. |
| `ui/RemoteWatchdogPanel.ps1` | Tray app with status, logs, settings, pending work, and network repair actions. / Durum, günlük, ayarlar, bekleyen işler ve ağ onarımı işlemlerini içeren tepsi uygulaması. |
| `lib/` | Shared helpers, JSON handling, TCP checks, settings contract, and normalization helpers. / Paylaşılan yardımcılar, JSON işlemleri, TCP kontrolleri, ayar sözleşmesi ve normalizasyon yardımcıları. |
| `install/` | Host/client installers with hash verification and task registration. / Hash doğrulaması ve görev kaydı içeren kurulum betikleri. |
| `tests/` | Regression tests to validate watchdog behavior and UI flows. / Watchdog davranışını ve arayüz akışını doğrulayan regresyon testleri. |

## Installation / Kurulum

### English

Copy or clone the repository to the target machine, then verify the files before running anything:

```powershell
.\tools\Verify-Hashes.ps1
```

Then install the host or client:

```powershell
# Remote PC (host, Administrator required)
powershell -ExecutionPolicy Bypass -File .\install\Install-Host.ps1 -TelegramToken '123:ABC' -TelegramChatId '456'

# Your own PC (client, no admin required)
powershell -ExecutionPolicy Bypass -File .\install\Install-Client.ps1 -Target '100.64.1.5:3389' -RdpFile 'C:\rdp\office.rdp' -TelegramToken '123:ABC' -TelegramChatId '456'
```

### Türkçe

Depoyu hedef makinaya kopyala veya klonla, ardından hiçbir şeyi çalıştırmadan önce dosyaları doğrula:

```powershell
.\tools\Verify-Hashes.ps1
```

Sonra host veya client kurulumunu çalıştır:

```powershell
# Uzak PC (host, Yönetici gerekli)
powershell -ExecutionPolicy Bypass -File .\install\Install-Host.ps1 -TelegramToken '123:ABC' -TelegramChatId '456'

# Kendi bilgisayarın (client, yönetici gerektirmez)
powershell -ExecutionPolicy Bypass -File .\install\Install-Client.ps1 -Target '100.64.1.5:3389' -RdpFile 'C:\rdp\office.rdp' -TelegramToken '123:ABC' -TelegramChatId '456'
```

> Security note / Güvenlik notu: the installer validates SHA256 values and aborts on mismatch. / kurulum betiği SHA256 doğrulamasını yapar ve uyumsuzlukta işlemi durdurur.

## Panel / Tray panel

### English

Start the tray panel directly:

```powershell
.\ui\RemoteWatchdogPanel.ps1
```

Useful options:

```powershell
.\ui\RemoteWatchdogPanel.ps1 -Install
.\ui\RemoteWatchdogPanel.ps1 -SelfTest
```

The tray icon changes color based on status: green = healthy, red = problem, gray = no data. It includes status, pending work, settings, and log tabs.

### Türkçe

Tepsi panelini doğrudan başlat:

```powershell
.\ui\RemoteWatchdogPanel.ps1
```

İşe yarar seçenekler:

```powershell
.\ui\RemoteWatchdogPanel.ps1 -Install
.\ui\RemoteWatchdogPanel.ps1 -SelfTest
```

Tepsi simgesi duruma göre renk değiştirir: yeşil = sağlıklı, kırmızı = sorun, gri = veri yok. Durum, bekleyen işler, ayarlar ve günlük sekmeleri bulunur.

## Repair flow / Onarım akışı

### English

When the panel triggers a repair, the remote machine tries the network recovery ladder in order:

1. Flush DNS cache
2. Renew DHCP lease
3. Reconnect the adapter / network stack
4. Restart critical services and driver path
5. Reset Winsock / IPv4
6. Reboot only if the failure is still present and policy allows it

The repair runs as SYSTEM, so a user session can request it without a UAC prompt. The system writes a repair request to a file and a scheduled watcher task applies it.

### Türkçe

Panel bir onarım tetiklediğinde uzak makine ağ kurtarma basamaklarını sırayla dener:

1. DNS önbelleğini temizle
2. DHCP sözleşmesini yenile
3. Ağ bağdaştırıcısını / ağ yığınını yeniden bağlat
4. Kritik servisleri ve sürücü yolunu yeniden başlat
5. Winsock / IPv4 sıfırla
6. Hala sorun varsa ve politika izin veriyorsa sadece o zaman yeniden başlat

Onarım SYSTEM hesabı ile çalışır; böylece kullanıcı oturumu UAC penceresi açmadan onarım isteyebilir. Sistem bir onarım isteğini dosyaya yazar ve zamanlanmış izleyici görevi bunu uygular.

## Security / Güvenlik

### English

- Verify the repository files with `Verify-Hashes.ps1` before use.
- Telegram token is stored in `config.json` securely when possible (DPAPI-backed handling for the Windows local machine scope).
- Do not pass secrets directly on a command line where possible.
- Keep the Windows host machine patched and the network path validated.

### Türkçe

- Kullanımdan önce dosyaları `Verify-Hashes.ps1` ile doğrula.
- Telegram token, mümkün olduğunda `config.json` içinde güvenli şekilde tutulur (Windows yerel makine kapsamı için DPAPI destekli kullanım).
- Gizli bilgileri mümkün olduğunca komut satırına doğrudan geçirme.
- Windows host makinesini güncel tut ve ağ yolunu doğrula.

## Health checks / Sağlık kontrolleri

### English

The watchdog can report health through Telegram and healthchecks.io, and the repo also includes a GitHub Actions workflow to ping the machine externally.

### Türkçe

Watchdog, Telegram ve healthchecks.io üzerinden sağlık bildirimi yapabilir; ayrıca repo içinde makinayı harici olarak yoklayan bir GitHub Actions akışı da bulunur.

## Contributing / Katkı

- See [CONTRIBUTING.md](CONTRIBUTING.md) for project rules and pull-request flow.
- [CONTRIBUTING.en.md](CONTRIBUTING.en.md) is the English version.
- Gelişime katkıda bulunmak için [CONTRIBUTING.md](CONTRIBUTING.md) dosyasına bak.

## License / Lisans

This project is licensed under the MIT License. See [LICENSE](LICENSE).

Bu proje MIT Lisansı altında lisanslanmıştır. [LICENSE](LICENSE) dosyasına bakın.

## Quick start / Hızlı başlangıç

### English

```powershell
.\tools\Verify-Hashes.ps1
powershell -ExecutionPolicy Bypass -File .\install\Install-Host.ps1 -TelegramToken '123:ABC' -TelegramChatId '456'
.\ui\RemoteWatchdogPanel.ps1
```

### Türkçe

```powershell
.\tools\Verify-Hashes.ps1
powershell -ExecutionPolicy Bypass -File .\install\Install-Host.ps1 -TelegramToken '123:ABC' -TelegramChatId '456'
.\ui\RemoteWatchdogPanel.ps1
```

This README is intentionally bilingual so both English and Turkish readers have the same operational guidance. / Bu README kasıtlı olarak çift dillidir; böylece hem İngilizce hem Türkçe okuyucular aynı operasyonel rehbere sahip olur.
