<div dir="rtl">

# نصب

[بازگشت به README](../../README.fa.md) · [English](../en/installation.md)

## پیش از شروع

- با **SSH مستقیم** وصل شو، نه از طریق VPN‌ای که قرار است تغییر کند.
- برای سرور جدید از یک VPS تازهٔ **Ubuntu 24.04 یا 26.04** (`amd64` یا `arm64`) با دستگاه TUN استفاده کن.
- پورت UDP مربوط به VPN را باید در فایروال ارائه‌دهنده باز کنی. ابزار آن فایروال را نمی‌بیند و تغییر نمی‌دهد.
- برای لینک موقت هم یک پورت TCP لازم است؛ پیش‌فرض ۴۴۳، ۸۴۴۳ یا ۹۴۴۳.

## سرور جدید

</div>

```bash
curl -fsSL https://github.com/MohZeh/darban-ovpn/releases/latest/download/get.sh -o get.sh
sudo bash get.sh
sudo darban
```

<div dir="rtl">

برای نصب نسخهٔ مشخص، حتی نسخهٔ پیش از انتشار، `get.sh` را از همان نسخه بگیر و اجرا کن:

</div>

```bash
sudo bash get.sh --version v1.0.0-rc.1
```

<div dir="rtl">

`get.sh` نسخه را دانلود و با `SHA256SUMS` مقایسه می‌کند و اگر یکی نباشند، چیزی اجرا نمی‌شود.

### پرسش‌های نصب

| پرسش | پیش‌فرض |
|---|---|
| hostname یا IP سرور | IPv4 عمومی تشخیص‌داده‌شده |
| پورت UDP سرور | `1194` |
| افزودن قوانین `ufw` (فقط اگر فعال باشد) | خیر |

اگر می‌توانی hostname بده تا انتقال سرور در آینده راحت‌تر باشد. رکورد DNS نباید پروکسی شود؛ مثلاً Cloudflare باید روی DNS only باشد، چون این ترافیک UDP است.

پیش از هر تغییر، برنامهٔ کامل، از جمله فهرست بسته‌های کرنل از شبیه‌سازی خود `apt`، نمایش داده می‌شود و تأیید می‌گیرد.

### کارهایی که نصب انجام می‌دهد

- افزودن مخزن رسمی OpenVPN (کانال stable) و نصب `openvpn`، `easy-rsa`، `socat` و `nftables`
- اگر کرنل فعلی ماژول `ovpn` نداشته باشد، نصب `linux-image-virtual-hwe-24.04` یا `linux-image-virtual-hwe-26.04`، متناسب با سیستم، بدون بسته‌های پیشنهادی. ماژول داخل همین کرنل است، پس DKMS و headers لازم نیست. اگر `apt` بستهٔ firmware یا گرافیکی برنامه‌ریزی کند، نصب متوقف می‌شود. روی container یا کرنلی که ماژول را دارد چیزی نصب نمی‌شود؛ `--install-kernel` کرنل را در هر حال نصب می‌کند.
- ساخت CA در `/root/pki` و گواهی سرور با اعتبار ۱۰ سال
- نوشتن `/etc/openvpn/server/server.conf`، فعال‌سازی IPv4 forwarding و NAT فقط برای VPN در جدول nftables جدا
- راه‌اندازی OpenVPN

اگر کرنل نصب شود، کرنل فعلی به‌عنوان پشتیبان می‌ماند و Reboot خودکار انجام نمی‌شود. VPN همان لحظه بدون DCO کار می‌کند. **هر وقت مناسب بود Reboot کن** تا کرنل جدید و DCO فعال شوند.

### پیش‌فرض‌هایی که بعداً قابل تغییرند

| تنظیم | پیش‌فرض |
|---|---|
| شبکهٔ VPN | اولین `/24` آزاد از `10.8.0.0` |
| مسیر ترافیک | همهٔ ترافیک IPv4 کلاینت |
| DNS کلاینت | `1.1.1.1` و `8.8.8.8` |

تغییر آن‌ها از **Settings › Advanced** انجام می‌شود.

### اجرا بدون پرسش

از پوشهٔ آرشیو استخراج‌شدهٔ یک نسخه:

</div>

```bash
sudo bash setup/server-setup.sh --host vpn.example.com --port 1194 --subnet 10.8.0.0 --dns "1.1.1.1 8.8.8.8" --yes
sudo bash setup/install.sh
```

<div dir="rtl">

اگر نصب نیمه‌کاره بماند، همان دستور را دوباره اجرا کن: از همان‌جا ادامه می‌دهد و دستور برگرداندن همهٔ تغییرات را هم نشان می‌دهد. گزینه‌های `--split-tunnel`، `--open-ufw` و `--install-kernel` هم هست. با `--yes`، `ufw` بدون `--open-ufw` تغییر نمی‌کند.

## سروری که OpenVPN دارد

اگر `/etc/openvpn/server/server.conf` وجود داشته باشد، `get.sh` مرحلهٔ نصب سرور را اجرا نمی‌کند و نصب‌کننده هم تنظیمات OpenVPN را تغییر نمی‌دهد و آن را Restart نمی‌کند. این ساختار لازم است:

- OpenVPN 2.7 با `udp4` و دقیقاً یک `tls-crypt` که از `/etc/openvpn/server/tls-crypt.key` استفاده کند
- Easy-RSA 3 در `/usr/share/easy-rsa/easyrsa`، با PKI در `/root/pki` و کلید CA بدون رمز
- ثبت گواهی سرور در `index.txt` همان PKI
- `crl-verify /etc/openvpn/server/crl.pem` با یک CRL معتبر
- سرویس فعال `openvpn-server@server.service`

اگر بررسی‌ای رد شود، نصب‌کننده پیش از نصب متوقف می‌شود و دلیل را می‌گوید. روی چنین سروری **Remove everything** رد می‌شود و تغییر شبکهٔ VPN هم مجاز نیست، چون NAT آن را این ابزار مدیریت نمی‌کند.

برای قطع نشست تکی، یک management socket محلی اضافه کن. در نبود آن، ابزار Restart کامل را پیشنهاد می‌دهد.

## بررسی نصب

</div>

```bash
sudo darban status
systemctl is-active openvpn-server@server.service darban-crl.timer
sudo darban-crl-maintain --check
```

<div dir="rtl">

## فهرست فایروال

| پورت | کاربرد |
|---|---|
| پورت UDP انتخابی | کلاینت‌های VPN |
| TCP 443، 8443 یا 9443 | لینک موقت |
| TCP 80، برای چند لحظه | فقط هنگام دریافت گواهی Let's Encrypt |

</div>
