# iPad 2 (iOS 6.1.3) Jailbreak Dev Environment Setup

Quick-reference guide for restoring a jailbroken iPad 2 from scratch to a
working MobileSubstrate tweak development environment.

## 1. Restore & Jailbreak

1. Put iPad in DFU mode, restore to iOS 6.1.3 via iTunes (IPSW: `iPad2,2_6.1.3_10B329`)
2. Jailbreak with p0sixspwn (or evasi0n6)
3. Open Cydia once — let it finish "Preparing Filesystem" and initial package refresh

## 2. Add Extra Repos

SSH in and write the extra sources list:

```bash
sshpass -p alpine ssh root@<DEVICE_IP> 'cat > /etc/apt/sources.list.d/extra.list << "EOF"
deb http://rejail.ru/ ./
deb http://apt.calvink19.uk/crackedarchive/ ./
deb http://rpetri.ch/repo/ ./
deb http://cydia.vn/ ./
deb http://yzu.moe/dev/ ./
deb http://repo.victorlobe.me/ ./
deb http://repo.legacyios.com/ ./
deb http://cydia.invoxiplaygames.uk/beta/ ./
deb http://cydia.invoxiplaygames.uk/ ./
deb http://apt.philippe97.ca/ ./
EOF'
```

Then update:

```bash
ssh root@<IP> 'apt-get update'
```

Some repos may 404 — that's fine, the important ones (saurik, bigboss, rpetri.ch,
rejail, yzu.moe, calvink19, legacyios, invoxiplaygames) are alive.

## 3. Install Packages

### Essential base (if not already present)

```bash
apt-get -y install openssh coreutils make ldid mobilesubstrate \
  preferenceloader syslogd grep
```

### Dev toolchain (Coolstar's on-device clang 3.7.1)

```bash
apt-get -y install org.coolstar.llvm-clang org.coolstar.llvm-clang32 \
  org.coolstar.cctools org.coolstar.ld64 org.coolstar.iostoolchain
```

### Tweak support libs

```bash
apt-get -y --force-yes install net.limneos.classdump-dyld \
  com.rpetrich.rocketbootstrap applist com.a3tweaks.flipswitch \
  com.chpwn.iconsupport p7zip winterboard \
  com.ixmoe.1pwn.veteris moe.yzu.veterishelper \
  ai.akemi.appsyncunified
```

(`--force-yes` needed for packages from unsigned repos.)

## 4. Push SDK Headers

The on-device clang has no system headers. Copy them from the host:

```bash
# From host machine:
sshpass -p alpine scp -O -r /home/bryan/theos/sdks/iPhoneOS6.1.sdk/usr \
  root@<IP>:/var/sdk/

sshpass -p alpine ssh root@<IP> 'mkdir -p /var/sdk/System'
sshpass -p alpine scp -O -r /home/bryan/theos/sdks/iPhoneOS6.1.sdk/System/Library \
  root@<IP>:/var/sdk/System/
```

Note: use `scp -O` (legacy protocol) — the device's old sshd doesn't support
the new sftp-based scp.

## 5. Class-Dump SpringBoard

```bash
ssh root@<IP> 'mkdir -p /var/sdk/usr/local/include/SpringBoard && \
  classdump-dyld -h -o /var/sdk/usr/local/include/SpringBoard \
  /System/Library/CoreServices/SpringBoard.app/SpringBoard'
```

Produces ~497 header files.

## 6. Compile a Tweak

Working build command:

```bash
clang -isysroot /var/sdk \
  -I/var/sdk/usr/local/include \
  -dynamiclib \
  /usr/lib/libsubstrate.dylib \
  -lobjc \
  -Wl,-undefined,dynamic_lookup \
  -o /tmp/MyTweak.dylib \
  MyTweak.m
```

Key flags:
- `-isysroot /var/sdk` — points clang at the SDK for system headers
- `-I/var/sdk/usr/local/include` — for class-dumped SpringBoard headers
- `/usr/lib/libsubstrate.dylib` — full path (not `-lsubstrate`) because
  `-isysroot` redirects the library search path away from `/usr/lib`
- `-Wl,-undefined,dynamic_lookup` — resolves CoreFoundation etc. symbols
  at load time (they're already in SpringBoard's address space)

Sign and install:

```bash
ldid -S /tmp/MyTweak.dylib
cp /tmp/MyTweak.dylib /Library/MobileSubstrate/DynamicLibraries/
# Also install the .plist filter alongside it
killall SpringBoard   # respring to load
```

## 7. Rollback a Bad Tweak

```bash
rm /Library/MobileSubstrate/DynamicLibraries/MyTweak.*
killall SpringBoard
```

If the device is bootlooped and SSH is still reachable (OpenSSH starts before
SpringBoard), connect and remove the dylib. If SSH is unreachable, DFU restore
is the only option.

## Dead Repos (as of Feb 2026)

These no longer resolve or 404:
- `cydia.zodttd.com` — DNS dead
- `pwnage.dev` — DNS dead
- `repo666.ultrasn0w.com` — 400
- `kok3shidoll.github.io/repo` — 404
- `calvink19.co/hyi` — 404
- `cydia.bag-xml.com` — DNS dead
