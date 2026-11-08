<div dir="rtl">

# کارهای روزمره

[بازگشت به README](../../README.fa.md) · [English](../en/usage.md)

منو را با این دستور باز کن:

</div>

```bash
sudo darban
```

<div dir="rtl">

بالای منو وضعیت سرور، [فهرست مسدودها](glossary.md#blocklist)، کلاینت‌ها و هر مشکلی را که نیاز به توجه دارد نشان می‌دهد.

## چطور جواب بدهی

- **در فهرست گزینه‌ها:** خط `Enter: ...` می‌گوید Enter الان چه می‌کند. برای گزینهٔ دیگر، `↑`/`↓` یا شمارهٔ آن را بزن و بعد Enter. `Esc` لغو می‌کند. جابه‌جایی به‌تنهایی کاری انجام نمی‌دهد.
- **در پرسشی که پیشنهاد دارد:** Enter مقدار داخل کروشه را قبول می‌کند.
- **در پرسشی که پیشنهاد ندارد:** Enter خالی لغو می‌کند.

پرسش‌های پرخطر روی جواب امن شروع می‌شوند. ارقام فارسی هم کار می‌کنند.

## افزودن یک نفر یا دستگاه

1. `2` یعنی **Create client** را بزن و نامی مثل `ali-phone` بنویس.
2. روش فرستادن پروفایل را انتخاب کن. [اشتراک پروفایل](sharing.md) را ببین.

بهتر است هر دستگاه کلاینت خودش را داشته باشد تا بتوانی یکی را بدون اثر روی بقیه حذف کنی.

## دیدن افراد متصل

**8 Maintenance & diagnostics** و بعد `4` یعنی **Connected now** را باز کن. بالای منو هم تعدادشان را نشان می‌دهد.

## دیدن همهٔ کلاینت‌ها

`1` یعنی **List clients** را بزن. نشان می‌دهد چه کسانی معتبرند و گواهی هرکدام کی منقضی می‌شود. کلاینت‌های باطل‌شده پنهان‌اند و ابزار نمایش آن‌ها را پیشنهاد می‌دهد.

## فرستادن دوبارهٔ پروفایل

مثلاً بعد از تعویض گوشی یا تغییر آدرس سرور:

1. `4` یعنی **Share a profile** را بزن.
2. کلاینت و روش فرستادن را انتخاب کن.

## حذف یک نفر یا دستگاه

1. `3` یعنی **Revoke client (permanent)** را بزن و کلاینت را انتخاب کن.
2. `2` را بزن تا روی گزینهٔ ابطال برود و بعد Enter بزن.

پروفایل قدیمی همه‌جا از کار می‌افتد و اتصال فعلی همان کلاینت قطع می‌شود. بقیهٔ کاربران تأثیری نمی‌بینند. اگر قطع همان یک اتصال ممکن نباشد، مثلاً روی سروری که این ابزار نساخته، ابزار این را می‌گوید و می‌پرسد OpenVPN را ری‌استارت کند یا نه، که همه را چند ثانیه قطع می‌کند. اگر جواب No بدهی، اتصال باز ممکن است تا یک ساعت بماند. این کار برگشت ندارد، ولی بعداً می‌توانی کلاینت جدیدی با همان نام بسازی.

## لغو لینکی که استفاده نشده

`5` یعنی **Active links** را بزن و لینک را انتخاب کن.

## حذف پروفایل مانده روی سرور

`6` یعنی **Delete server copy** را بزن. کلاینت به کار خود ادامه می‌دهد و فقط فایل روی سرور حذف می‌شود.

## تغییر آدرس یا پورت سرور

**7 Settings** را باز کن:

- `1` یعنی **Server address**
- `2` یعنی **OpenVPN UDP port**

بعد از تغییر هرکدام، پروفایل‌ها را دوباره بفرست، چون هر پروفایل آدرسی را نگه می‌دارد که با آن ساخته شده است. پورت جدید باید در فایروال ارائه‌دهنده هم باز باشد.

## به‌روزرسانی ابزار

دستور نصب را دوباره اجرا کن، یا از **9 Setup** گزینهٔ `1` یعنی **Check for updates** را بزن:

</div>

```bash
sudo darban update
```

<div dir="rtl">

فقط خود ابزار عوض می‌شود. OpenVPN ری‌استارت نمی‌شود و کلاینت‌ها دست نمی‌خورند. برای برگشت، از **9 Setup** گزینهٔ `2` یعنی **Restore previous version** را بزن.

## بررسی سرور

**8 Maintenance & diagnostics** و بعد `1` یعنی **Diagnostics** را باز کن، یا این را اجرا کن:

</div>

```bash
sudo darban status
```

<div dir="rtl">

کد خروج وقتی بررسی‌ای مشکل پیدا کند `1` و در غیر این صورت `0` است، پس در اسکریپت هم قابل استفاده است. هشدارها آن را تغییر نمی‌دهند. بررسی‌ها روی خود سرور انجام می‌شوند، پس فایروال ارائه‌دهنده را نمی‌بینند. اگر مشکلی بود، [عیب‌یابی](troubleshooting.md) را ببین.

## حذف ابزار

**9 Setup** را باز کن:

- `5` یعنی **Uninstall this tool only:** OpenVPN به کار خود ادامه می‌دهد.
- `6` یعنی **Remove everything:** ابزار، OpenVPN و همهٔ کلاینت‌ها. همهٔ پروفایل‌ها از کار می‌افتند، مگر پشتیبان را برگردانی.

[اینکه هرکدام چه چیزی را حذف می‌کند](advanced.md#removal) را ببین.

## همهٔ دستورها

</div>

```bash
sudo darban                # menu
sudo darban --no-clear     # menu that never clears the screen
sudo darban list           # active clients
sudo darban list --all     # including revoked clients
sudo darban connected      # clients connected right now
sudo darban status         # diagnostics checklist
sudo darban repair-crl     # publish a fresh blocklist and finish a revocation
sudo darban update         # check for a release and install it
sudo darban about          # version, project address and contact
sudo darban uninstall      # remove only this tool
sudo darban remove-all     # remove this tool, OpenVPN, the CA and profiles
sudo darban version
sudo darban help
```

<div dir="rtl">

منو بعد از ۱۵ دقیقه بدون ورودی بسته می‌شود. `NO_COLOR=1` رنگ‌ها را خاموش می‌کند. کارها در journal سیستم ثبت می‌شوند: `sudo journalctl -t darban`

</div>
