# Connect a device

[Back to README](../../README.md) · [فارسی](../fa/connect-devices.md)

For the person who received a link or a `.ovpn` file. The app is **OpenVPN Connect**, from the OpenVPN project.

## Get the profile

1. Open the link you received. If the browser warns that the connection is not private, go on only if the sender told you to expect it for this link: choose **Advanced** and then **Continue**. Otherwise stop, and ask the sender.
2. Press **Get my profile**. The link works only once, so do this on the device you want to connect.
3. On the next page, press **Download .ovpn**. This page works for 10 minutes.

The page also has an **OpenVPN Connect** button that tries to open the app directly. If it does not work, use the download button.

The file holds a private key. Do not share or publish it.

## Android

1. Install [OpenVPN Connect from Google Play](https://play.google.com/store/apps/details?id=net.openvpn.openvpn).
2. Open the app and go to **My Profiles**.
3. Press the add icon, then **Upload File**, and choose the downloaded `.ovpn` file.
4. Confirm the import, and press **Connect**.

## iPhone and iPad

1. Install [OpenVPN Connect from the App Store](https://apps.apple.com/app/openvpn-connect/id590379981).
2. After downloading the file, open it from the **Files** app and share it to **OpenVPN**. If that option is missing, save it in **Files › On My iPhone** first, and share it from there. Avoid cloud storage: the file holds your private key.
3. Confirm the import, and press **Connect**.

## Windows and macOS

1. Install [OpenVPN Connect from openvpn.net](https://openvpn.net/client/).
2. Double-click the downloaded `.ovpn` file, or drag it onto the app.
3. Confirm the import, and press **Connect**.

## Linux

On Ubuntu or Debian, install the client and start it with the file. Write the real name of your file instead of `client1.ovpn`. Other distributions have the same `openvpn` package in their own package manager.

```bash
sudo apt install -y openvpn
```

```bash
sudo openvpn --config client1.ovpn
```

**You should see:** `Initialization Sequence Completed`. Press `Ctrl+C` to disconnect. This simple form does not change the DNS settings of your computer.

## Check that it works

While connected, open [api.ipify.org](https://api.ipify.org). It should show the address of the VPN server, not your usual one.

**If it does not connect:** tell the server administrator, and see [Troubleshooting](troubleshooting.md).

## If the profile has a password

If the administrator locked the key, the app asks for a password. The administrator sends it separately from the link.

## If screens look different

App screens change over time. See [OpenVPN's own guide to importing a profile](https://openvpn.net/connect-docs/import-profile/).
