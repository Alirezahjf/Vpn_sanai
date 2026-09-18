# vpn-sanai 🇮🇷

نصب‌کنندهٔ حرفه‌ای، خودکار و امنِ **پنل سنایی (3x-ui)** همراه با کانفیگ **VLESS + REALITY** — بدون نیاز به دامنه، فقط با IP.

> این پروژه پنل را از صفر نصب می‌کند، یک Inbound بهینهٔ VLESS+REALITY (با xtls-rprx-vision) می‌سازد، فایروال و fail2ban و BBR را تنظیم می‌کند، پشتیبان‌گیری خودکار راه می‌اندازد و در پایان لینک + QR کد کلاینت را تحویل می‌دهد.

---

## فهرست

- [امکانات](#امکانات)
- [پیش‌نیازها](#پیشنیازها)
- [نصب سریع](#نصب-سریع)
- [نصب گام‌به‌گام](#نصب-گامبهگام)
- [دسترسی به پنل](#دسترسی-به-پنل)
- [ربات تلگرام](#ربات-تلگرام)
- [مدیریت کلاینت‌ها](#مدیریت-کلاینتها)
- [پشتیبان‌گیری و بازگردانی](#پشتیبانگیری-و-بازگردانی)
- [امنیت سرور](#امنیت-سرور)
- [همهٔ گزینه‌های خط فرمان](#همهٔ-گزینههای-خط-فرمان)
- [ساختار پروژه](#ساختار-پروژه)
- [رفع اشکال](#رفع-اشکال)
- [حذف نصب](#حذف-نصب)
- [توسعه و تست](#توسعه-و-تست)

---

## امکانات

| بخش | توضیح |
|---|---|
| **نصب پنل** | نصب رسمی 3x-ui به‌صورت غیرتعاملی، با نسخهٔ پین‌شده یا `latest`، رمز و مسیر پنل تصادفی و قوی |
| **کانفیگ پیش‌فرض** | VLESS + REALITY + `xtls-rprx-vision` روی TCP، پورت ۴۴۳ (در صورت اشغال، انتخاب خودکار پورت آزاد) |
| **انتخاب هوشمند SNI** | نامزدها با TLS 1.3 + HTTP/2 + گواهی معتبر آزمایش می‌شوند و سریع‌ترین گزینه انتخاب می‌شود |
| **xHTTP (اختیاری)** | ساخت هم‌زمان یک Inbound دوم با انتقال xHTTP برای مقاومت بیشتر |
| **کلاینت و QR** | ساخت کلاینت با محدودیت حجم/زمان/IP، تولید لینک و QR کد در ترمینال + ذخیره در فایل |
| **لینک اشتراک** | Subscription روی پورت اختصاصی (پیش‌فرض ۲۰۹۶) |
| **فایروال** | UFW با قواعد دقیق؛ فقط پورت‌های لازم باز می‌شوند |
| **fail2ban** | Jail اختصاصی برای SSH (روی پورت جدید هم اعمال می‌شود) |
| **تغییر پورت SSH** | با اعتبارسنجی `sshd -t`، باز نگه‌داشتن پورت قبلی و نهایی‌سازی با یک دستور |
| **BBR + تنظیمات شبکه** | فعال‌سازی BBR با fq و sysctl بهینه برای اتصال‌های هم‌زمان زیاد |
| **همگام‌سازی ساعت** | مهم برای REALITY (اختلاف ساعت باعث شکست دست‌دادن می‌شود) |
| **پشتیبان‌گیری** | پشتیبان روزانهٔ دیتابیس + state + گواهی‌ها (cron) با نگهداری ۱۴ روز |
| **منوی مدیریت** | دستور `vpn-sanai` برای وضعیت، افزودن کلاینت، پشتیبان‌گیری، به‌روزرسانی و حذف |
| **ربات تلگرام** | مدیریت کامل سرور از تلگرام: کلاینت‌ها، تنظیمات و لینک پنل، امنیت، پشتیبان — با احراز هویت مدیران، حذف خودکار پیام‌های محرمانه و گزارش روزانه |
| **امنیت اجرا** | `set -Eeuo pipefail`، قفل اجرای هم‌زمان، trap خطا، لاگ کامل، حالت `--dry-run` |

---

## پیش‌نیازها

- سرور **Debian 11/12، Ubuntu 20.04+، Alma/Rocky/RHEL 8+، Fedora، Arch یا Alpine** (systemd یا openrc)
- معماری `x86_64`، `arm64` یا `armv7` (سایر معماری‌های پشتیبانی‌شده توسط xray هم کار می‌کنند)
- دسترسی **root** (اسکریپت خودش با `sudo` دوباره اجرا می‌شود)
- حداقل ۲۰۰ مگابایت رم و ۵۰۰ مگابایت فضای دیسک
- دسترسی خروجی به GitHub برای دانلود پنل (در صورت فیلتر: پروکسی یا آینه‌ها — پایین را ببینید)
- **دامنه لازم نیست.** همه‌چیز با IP کار می‌کند.

---

## نصب سریع

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Alirezahjf/Vpn_sanai/main/install.sh)
```

اسکریپت کل پروژه را خودش دانلود می‌کند (از چند آینه به‌ترتیب)، سپس نصب را شروع می‌کند و در چند نقطه سؤال می‌پرسد.
برای نصب کاملاً بدون سؤال (با پیش‌فرض‌های امن) کافی است `-y` اضافه کنید:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Alirezahjf/Vpn_sanai/main/install.sh) -y
```

**اگر GitHub در شبکهٔ شما محدود است:**

```bash
# روش ۱: پروکسی
export https_proxy=http://user:pass@host:port
bash <(curl -Ls https://raw.githubusercontent.com/Alirezahjf/Vpn_sanai/main/install.sh)

# روش ۲: از آینهٔ jsDelivr
bash <(curl -Ls https://cdn.jsdelivr.net/gh/Alirezahjf/Vpn_sanai@main/install.sh)

# روش ۳: دانلود ZIP از GitHub و اجرای محلی
unzip Vpn_sanai-main.zip && cd Vpn_sanai-main && bash install.sh
```

---

## نصب گام‌به‌گام

اسکریپت این مراحل را به‌ترتیب انجام می‌دهد (هر مرحله در لاگ ثبت می‌شود):

1. **پیش‌بررسی**: تشخیص توزیع/معماری، بررسی منابع، شبکه و نصب بسته‌های لازم (`curl`, `jq`, `openssl`, `socat`, `qrencode`, `sqlite3`, …)
2. **منطقهٔ زمانی و ساعت**: تنظیم `Asia/Tehran` و همگام‌سازی NTP
3. **تشخیص IP عمومی** و تأیید آن توسط شما
4. **پرسش‌های پیکربندی**: حالت دسترسی پنل، پورت پنل، پورت VLESS، xHTTP، کلاینت پیش‌فرض، تنظیمات امنیتی
5. **نصب پنل** با نصب‌کنندهٔ رسمی 3x-ui (غیرتعاملی) و دریافت توکن API
6. **ساخت Inbound** ولِس + REALITY با کلید تازه، shortId تصادفی و بهترین SNI
7. **ساخت کلاینت** و چاپ لینک/QR + لینک اشتراک
8. **تغییر پورت SSH** (اختیاری، با اعتبارسنجی و امکان برگشت)
9. **فایروال + fail2ban + BBR + sysctl**
10. **پشتیبان اولیه + cron روزانه**، ذخیرهٔ گزارش در `/etc/vpn-sanai/report.txt`

در پایان چیزی شبیه این می‌بینید:

```
────────────────────────── خلاصهٔ نصب ──────────────────────────
  پنل (روی سرور)         https://127.0.0.1:23591/AbC123xyz/
  دسترسی از سیستم شما    ssh -N -L 8443:127.0.0.1:23591 root@1.2.3.4 -p 22
  سپس در مرورگر          https://127.0.0.1:8443/AbC123xyz/
  نام کاربری پنل         admin
  رمز عبور پنل           Xy7… (تصادفی)
─────────────────── کانفیگ VLESS + REALITY ───────────────────
  آدرس کلاینت            1.2.3.4:443
  SNI                    www.microsoft.com
  ShortId                a1b2c3d4e5f60718
  لینک                   vless://…@1.2.3.4:443?type=tcp&security=reality&…
                                                    ▄▄▄▄▄▄▄ ▄▄ ▄▄▄▄▄
                                                    █ ▄▄▄ █ ▀█▄ █▀ █
                                                    …
```

---

## دسترسی به پنل

### حالت `tunnel` (پیش‌فرض و امن‌ترین)

پنل فقط روی `127.0.0.1` گوش می‌دهد و از اینترنت دیده نمی‌شود. از سیستم خودتان یک تونل SSH بسازید:

```bash
ssh -N -L 8443:127.0.0.1:23591 root@SERVER_IP
```

سپس در مرورگر: `https://127.0.0.1:8443/AbC123xyz/`
(گواهی self-signed است؛ یک‌بار هشدار مرورگر را می‌پذیرید. حتی اگر «ادامه» بزنید، ترافیک رمزنگاری‌شده است.)

### حالت `public`

پنل روی همهٔ اینترفیس‌ها گوش می‌دهد: `https://SERVER_IP:PORT/AbC123xyz/`
پورت پنل به‌صورت خودکار در UFW باز می‌شود. گواهی self-signed است (بدون دامنه امکان گواهی معتبر وجود ندارد).

---

## ربات تلگرام

مدیریت کامل سرور از داخل تلگرام — بدون SSH و بدون مرورگر. ربات مستقیماً به API پنل سنایی (3x-ui) وصل می‌شود و همهٔ کارهای روزمره را با چند لمس انجام می‌دهد. سرویس به‌صورت systemd (`vpn-sanai-telegram.service`) با ری‌استارت خودکار اجرا می‌شود.

### راه‌اندازی

```bash
# ۱) از @BotFather یک ربات بسازید و توکن آن را بردارید
# ۲) راه‌اندازی (در پایان install.sh هم پیشنهاد می‌شود؛ گزینهٔ ۸ منو)
vpn-sanai-telegram --setup
# یا مستقیم با توکن و شناسهٔ مدیران:
vpn-sanai-telegram --setup --token "123456:ABC-DEF..." --admins 123456789
```

اگر `--admins` ندهید، ربات یک **کد جفت‌سازی یک‌بارمصرف** چاپ می‌کند؛ همان را در تلگرام بفرستید:

```
/start ABCD-1234
```

تا به‌عنوان مدیر اول ثبت شوید. پیام افراد ناشناس پاسخ داده نمی‌شود و تلاش‌های آن‌ها (با محدودیت تعداد) به مدیران اطلاع داده می‌شود.

### امکانات

| دستور / دکمه | کار |
|---|---|
| `/panel` | لینک ورود پنل (دستور تونل SSH یا آدرس عمومی)، نام کاربری و رمز — پیام‌های محرمانه بعد از ۹۰ ثانیه خودکار حذف می‌شوند |
| `/status` | وضعیت سرور و پنل: Xray، CPU، RAM، دیسک، تعداد کلاینت‌ها |
| `/add name 30 100 2` | ساخت کلاینت (روز / گیگابایت / محدودیت IP) — بدون آرگومان، ویزارد گفت‌وگویی ۴ مرحله‌ای |
| `/link name` | ارسال لینک و QR کلاینت |
| `/del name` | حذف کلاینت با تأیید دو مرحله‌ای |
| `/settings` | نمایش و تغییر پورت، مسیر مخفی، نام کاربری و رمز پنل + ری‌استارت امن (در صورت عدم پاسخ، بازگشت خودکار به پورت قبلی) |
| `/security` | وضعیت UFW و fail2ban، باز/بسته کردن پورت، آزادسازی IP بن‌شده |
| `/backup` | تهیهٔ پشتیبان فوری و ارسال فایل، فهرست، بازگردانی و پاک‌سازی |
| `/id` `/cancel` `/help` | شناسهٔ تلگرام، لغو عملیات جاری، راهنما |

نکته‌ها:

- اعداد فارسی هم پذیرفته می‌شوند (`۳۰` = 30).
- گزارش روزانهٔ وضعیت، هر روز صبح برای مدیران ارسال می‌شود (قابل تنظیم در `/etc/vpn-sanai/telegram.env`).
- پس از هر پشتیبان‌گیری موفق روزانه، نتیجه از طریق ربات اطلاع داده می‌شود.

### مدیریت سرویس ربات

```bash
vpn-sanai-telegram --status          # وضعیت سرویس و پیکربندی
vpn-sanai-telegram --log             # آخرین لاگ‌ها
vpn-sanai-telegram --restart         # ری‌استارت سرویس
vpn-sanai-telegram --check           # بررسی سلامت پیکربندی
vpn-sanai-telegram --notify "متن"    # ارسال پیام به مدیران (برای cron)
vpn-sanai-telegram --uninstall       # حذف سرویس و پیکربندی ربات
```

---

## مدیریت کلاینت‌ها

```bash
# افزودن کلاینت با محدودیت حجم و زمان
vpn-sanai-add-client --email ali --days 30 --gb 50

# محدودیت IP هم‌زمان + خروجی JSON
vpn-sanai-add-client --email reza --ip-limit 2 --json

# نمایش لینک و QR همهٔ کلاینت‌ها با مصرف
vpn-sanai-clients --usage

# فقط یک کلاینت، بدون QR
vpn-sanai-clients --email ali --no-qr
```

لینک‌ها در `/etc/vpn-sanai/links/` (فایل متنی + PNG) ذخیره می‌شوند و فهرست کلی در `links.txt` است.

**الگوی لینک تولیدشده:**

```
vless://UUID@IP:443?type=tcp&security=reality&pbk=PUBLIC_KEY&fp=chrome&sni=SNI&sid=SHORT_ID&spx=%2F&flow=xtls-rprx-vision#نام
```

---

## پشتیبان‌گیری و بازگردانی

```bash
vpn-sanai-backup                  # پشتیبان دستی
vpn-sanai-backup --list           # فهرست پشتیبان‌ها
vpn-sanai-backup --restore FILE   # بازگردانی
vpn-sanai-backup --prune --days 7 # پاک‌سازی
```

- پشتیبان شامل: دیتابیس پنل (`x-ui.db`)، `state.env`، `install-result.env`، گواهی‌ها، لینک‌ها و `MANIFEST.txt` است.
- دیتابیس با روش آنلاین SQLite (`.backup`) گرفته می‌شود؛ اگر ممکن نبود از API پنل و در نهایت کپی ساده استفاده می‌شود.
- **زمان‌بندی پیش‌فرض:** هر روز ساعت ۳:۳۰ بامداد (`/etc/cron.d/vpn-sanai-backup`) با نگهداری ۱۴ روز.
- پیش از هر بازگردانی، از دیتابیس فعلی نسخهٔ `.before-restore.<timestamp>` ساخته می‌شود.

---

## امنیت سرور

```bash
vpn-sanai-security --status              # خلاصهٔ وضعیت امنیتی
vpn-sanai-security --ssh-port 2222       # تغییر پورت SSH (پورت قبلی باز می‌ماند)
vpn-sanai-security --ssh-finalize        # بستن پورت‌های قبلی پس از تأیید اتصال
vpn-sanai-security --ufw-allow 8443/tcp  # باز کردن پورت دلخواه
vpn-sanai-security --fail2ban-unban 1.2.3.4
vpn-sanai-security --bbr                 # اعمال مجدد BBR + sysctl
```

نکات مهم:

- **پورت SSH**: پس از تغییر، پورت قدیمی هم باز می‌ماند تا اگر اتصال جدید کار نکرد قفل نشوید. با `--ssh-finalize` (یا منوی `vpn-sanai`) پورت قدیمی بسته می‌شود.
- **UFW**: اسکریپت هیچ‌وقت `ufw reset` نمی‌کند؛ اگر فایروال از قبل فعال باشد فقط قواعد لازم اضافه می‌شوند.
- **fail2ban**: jail اختصاصی `sshd` در `/etc/fail2ban/jail.d/99-vpn-sanai-sshd.local` ساخته می‌شود و jail خود پنل (`3x-ipl`) دست‌نخورده می‌ماند.
- **REALITY و ساعت**: اگر ساعت سرور ناهمگام باشد، کلاینت‌ها وصل نمی‌شوند. گام «همگام‌سازی ساعت» را جدی بگیرید.

---

## همهٔ گزینه‌های خط فرمان

```
bash install.sh [گزینهها]

--panel-mode MODE        tunnel (پیشفرض) | public
--panel-port PORT        پورت پنل (پیشفرض: تصادفی آزاد)
--panel-user NAME        نام کاربری پنل
--panel-pass PASS        رمز عبور پنل
--panel-base-path PATH   مسیر مخفی پنل (فقط حروف/عدد/-/_ مجاز است)
--panel-tls MODE         self-signed (پیشفرض) | none
--panel-version V        نسخهٔ 3x-ui (مثال v3.8.5) — پیشفرض latest
--installer-url URL      آدرس نصبکنندهٔ رسمی (شبکههای محدود)
--skip-panel-install     پنل از قبل نصب است؛ فقط پیکربندی کن
--reinstall-panel        نصب/بهروزرسانی پنل حتی اگر نصب باشد

--vless-port PORT        پورت کانفیگ (پیشفرض 443)
--sni HOST               دامنهٔ پوششی REALITY (پیشفرض: انتخاب خودکار)
--xhttp                  ساخت Inbound اضافه با انتقال xHTTP
--xhttp-port PORT        پورت Inbound دوم (پیش‌فرض 8443)
--client-email EMAIL     نام کلاینت پیشفرض
--client-total-gb N      حجم مجاز (0 = نامحدود)
--client-days N          اعتبار به روز (0 = نامحدود)
--client-ip-limit N      محدودیت IP همزمان (0 = نامحدود)
--sub-port PORT          پورت لینک اشتراک (پیشفرض 2096)
--no-subscription        غیرفعال کردن اشتراک

--ssh-port PORT          تغییر پورت SSH
--ssh-finalize           بستن پورت(های) قبلی SSH
--no-ufw --no-fail2ban --no-bbr --no-sysctl --no-timesync --no-backup

--status                 وضعیت نصب
--add-client EMAIL       افزودن کلاینت
--show-clients           لینک/QR همهٔ کلاینتها
--backup                 پشتیبانگیری دستی
--restore FILE           بازگردانی
--update-panel           بهروزرسانی پنل
--uninstall              حذف کامل
--menu                   منوی مدیریت

-y, --yes                غیرتعاملی
--dry-run                فقط نمایش دستورات
--debug / --quiet        لاگ کامل / فقط خطاها
```

نمونه‌ها:

```bash
bash install.sh -y                                        # نصب کامل خودکار
bash install.sh --panel-mode public --vless-port 8443 -y  # پنل عمومی، پورت غیر ۴۴۳
bash install.sh --ssh-port 2222 --xhttp --xhttp-port 8443 -y  # تغییر پورت SSH + xHTTP
bash install.sh --sni www.apple.com --client-days 30 -y   # SNI دستی + اعتبار ۳۰ روزه
```

---

## ساختار پروژه

```
install.sh              نقطهٔ ورود: bootstrap، پارس آرگومان، هماهنگی مراحل
lib/
  bootstrap.sh          دانلود خودکار پروژه هنگام اجرای curl|bash
  common.sh             لاگ، رنگ، اعتبارسنجی، پرامپت، فایل state، ابزارها
  preflight.sh          تشخیص توزیع، نصب بسته‌ها، منابع، شبکه، ساعت، پورت
  api.sh                کلاینت API پنل (Bearer / کوکی+CSRF) و تحلیل پاسخ
  panel.sh              نصب/پیکربندی پنل، گواهی، توکن، ری‌استارت Xray
  reality.sh            کلید REALITY، انتخاب SNI، ساخت Inbound، shareAddr
  clients.sh            ساخت/حذف کلاینت، ساخت لینک، QR، فایل لینک‌ها
  security.sh           UFW، fail2ban، SSH، BBR، sysctl
  backup.sh             پشتیبان‌گیری آنلاین، cron، نگهداری، بازگردانی
  telegram.sh           کلاینت Bot API: فراخوانی، صفحه‌کلید، قطعه‌بندی پیام بلند
  bot.sh                منطق ربات: منوها، ویزاردها، احراز هویت مدیران
  load.sh               نقطهٔ ورود مشترک برای اسکریپت‌های کمکی
scripts/                دستورات مستقل: add-client, show-clients, backup, security, status, telegram-bot, uninstall
config/defaults.conf    همهٔ پیش‌فرض‌ها (پورت‌ها، نامزدهای SNI، cron، …)
config/vpn-sanai-telegram.service   واحد systemd ربات
tests/                  تست‌های خودکار + پنل و ربات شبیه‌سازی‌شده (mock_panel.py, mock_telegram.py)
```

فایل‌های مهم روی سرور:

| مسیر | محتوا |
|---|---|
| `/etc/vpn-sanai/state.env` | وضعیت نصب و رازها (mode 600) |
| `/etc/vpn-sanai/report.txt` | گزارش آخرین نصب (mode 600) |
| `/etc/vpn-sanai/links/` | لینک و QR هر کلاینت |
| `/etc/vpn-sanai/telegram.env` | توکن و مدیران ربات (mode 600) |
| `/var/lib/vpn-sanai/telegram/` | وضعیت ربات: offset و نشست‌ها (mode 700) |
| `/etc/vpn-sanai/tls/` | گواهی self-signed پنل |
| `/var/log/vpn-sanai/` | لاگ نصب و اسکریپت‌ها |
| `/var/backups/vpn-sanai/` | پشتیبان‌های زمان‌بندی‌شده |
| `/etc/x-ui/x-ui.db` | دیتابیس پنل |
| `/usr/local/lib/vpn-sanai/` | نسخهٔ پایدار خود ابزار |

---

## رفع اشکال

<details>
<summary><b>نصب پنل دانلود نمی‌شود / GitHub فیلتر است</b></summary>

- با پروکسی اجرا کنید: `export https_proxy=http://user:pass@host:port`
- یا نصب‌کنندهٔ رسمی را دستی بدهید: `bash install.sh --installer-url https://آینه/install.sh`
- یا پنل را دستی نصب کنید و بعد: `bash install.sh --skip-panel-install`

</details>

<details>
<summary><b>کلاینت وصل نمی‌شود</b></summary>

1. ساعت سرور: `timedatectl` — باید همگام باشد (REALITY به اختلاف زمان حساس است).
2. SNI انتخاب‌شده از شبکهٔ شما قابل دسترسی باشد: در پنل مقدار `serverNames`/`target` را عوض کنید یا از `--sni` استفاده کنید.
3. پورت باز باشد: `vpn-sanai-security --status` و `ss -tlnp | grep xray`.
4. لاگ Xray: `journalctl -u x-ui -n 100 --no-pager` یا صفحهٔ Logs در پنل.
5. کلاینت قدیمی باشد: نسخهٔ v2rayNG / Nekobox / Streisand خود را به‌روز کنید (REALITY نیاز به نسخهٔ جدید دارد).

</details>

<details>
<summary><b>پورت ۴۴۳ اشغال است</b></summary>

اسکریپت خودش پورت آزاد انتخاب می‌کند و در گزارش می‌نویسد. برای انتخاب دستی: `--vless-port 8443`.
اگر می‌خواهید ۴۴۳ را آزاد کنید: `ss -tlnp | grep :443` و سرویس متخاصم را ببندید.

</details>

<details>
<summary><b>QR کد نمایش داده نمی‌شود</b></summary>

بستهٔ `qrencode` نصب نشده است: `apt install qrencode` (یا `dnf install qrencode`). لینک‌ها در هر حالت در `/etc/vpn-sanai/links/` ذخیره می‌شوند.

</details>

<details>
<summary><b>اتصال SSH بعد از تغییر پورت قطع شد</b></summary>

پورت قبلی از روی طراحی باز مانده است؛ با همان پورت قبلی وصل شوید و بعد `vpn-sanai-security --status` را بررسی کنید. برای برگشت سریع به پیکربندی اولیه:

```bash
rm -f /etc/ssh/sshd_config.d/99-vpn-sanai.conf && sshd -t && systemctl restart ssh
```

</details>

<details>
<summary><b>می‌خواهم روی سرور موجود نصب کنم</b></summary>

اسکریپت idempotent است: بار دوم نصب را رد می‌کند، توکن API را می‌خواند و فقط پیکربندی را دوباره اعمال می‌کند. برای نصب/به‌روزرسانی خود پنل از `--reinstall-panel` استفاده کنید.
اگر UFW از قبل فعال است، قواعد شما دست‌نخورده می‌مانند.

</details>

---

## حذف نصب

```bash
vpn-sanai-uninstall                 # تعاملی، با پشتیبان امنیتی قبل از حذف
vpn-sanai-uninstall --yes-all       # حذف کامل بدون پرسش
```

پیش از حذف به‌طور خودکار یک پشتیبان `pre-uninstall` گرفته می‌شود. سرویس ربات تلگرام متوقف و واحد systemd آن حذف می‌شود؛ پورت SSH اضافه‌شده و قواعد فایروال نیز پاک‌سازی می‌شوند.

---

## توسعه و تست

```bash
bash tests/run.sh             # اجرای همهٔ تست‌ها
bash tests/run.sh api         # فقط تست‌های API
bash tests/run.sh -v          # با جزئیات
shellcheck -x install.sh lib/*.sh scripts/*.sh   # بررسی ایستا
```

تست‌ها **آفلاین** اجرا می‌شوند و هیچ تغییری روی سیستم نمی‌دهند:

- همهٔ توابع خالص (`lib/common.sh`, `lib/reality.sh`, `lib/clients.sh`) تست واحد دارند.
- کلاینت API روی `tests/mock_panel.py` اجرا می‌شود؛ این پنل شبیه‌سازی‌شده همان اعتبارسنجی و پاسخ‌های پنل واقعی (شامل `{success:false,obj:{issues}}`، خطای «پورت اشغال»، اتصال مجدد کلاینت تکراری و رشته‌ای بودن `settings`) را تقلید می‌کند.
- مسیر `curl | bash` (bootstrap) با یک `curl` جعلی که فایل‌ها را از ریپوی محلی سرو می‌کند تست می‌شود.

`config/defaults.conf` را برای تغییر پیش‌فرض‌ها (پورت‌ها، نامزدهای SNI، کرون پشتیبان، منطقهٔ زمانی) ویرایش کنید.

---

## مجوز

MIT — فایل [LICENSE](LICENSE).

پنل 3x-ui متعلق به [MHSanaei](https://github.com/MHSanaei/3x-ui) است و این پروژه فقط نصب و پیکربندی آن را خودکار می‌کند.
