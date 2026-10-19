import CommonCrypto
import Foundation

// Configures a freshly installed macOS guest offline so it boots straight to an autologin desktop with SSH enabled.
// The approach follows Lume's MacOSOfflineSetupPatcher (MIT, github.com/trycua/cua).
struct Provisioner {
    static let usersDirectory = "private/var/db/dslocal/nodes/Default/users"
    static let groupsDirectory = "private/var/db/dslocal/nodes/Default/groups"
    static let sshAccessGroupID = "399"

    let disk: GuestDisk
    let username: String
    let password: String
    let authorizedKeys: Data
    let passwordlessSudo: Bool
    let osVersion: String
    let osBuild: String

    private let user = GuestDisk.Owner(uid: 501, gid: 20)
    private var home: String { "Users/\(username)" }

    func run() throws {
        let userUUID = try writeUserRecord()
        try addToGroups(userUUID: userUUID)
        try writeHome()
        try writeAuthorizedKeys(authorizedKeys, disk: disk, home: home, owner: user)
        try markSetupAssistantDone()
        try configureAutologin()
        try enableSSH()
        try disableSleepAndLock()
        if passwordlessSudo {
            try disk.write(
                Data("\(username) ALL=(ALL) NOPASSWD: ALL\n".utf8),
                to: "private/etc/sudoers.d/\(username)-nopasswd",
                owner: .root,
                mode: 0o440
            )
        }
    }

    private func writeUserRecord() throws -> String {
        let relative = "\(Provisioner.usersDirectory)/\(username).plist"
        var record = try disk.readPlist(relative)
        let userUUID = (record["generateduid"] as? [String])?.first ?? UUID().uuidString.uppercased()

        if record.isEmpty {
            try ensureUIDAvailable()
            record = [
                "_writers_UserCertificate": [username],
                "_writers_hint": [username],
                "_writers_jpegphoto": [username],
                "_writers_passwd": [username],
                "_writers_picture": [username],
                "_writers_realname": [username],
                "record_daemon_version": ["9040000"],
                "unlockOptions": ["0"]
            ]
        }
        record["ShadowHashData"] = [try shadowHashData()]
        record["authentication_authority"] = [";ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2>"]
        record["generateduid"] = [userUUID]
        record["gid"] = [String(user.gid)]
        record["home"] = ["/\(home)"]
        record["name"] = [username]
        record["passwd"] = ["********"]
        record["realname"] = [username]
        record["shell"] = ["/bin/zsh"]
        record["uid"] = [String(user.uid)]

        try disk.writePlist(record, to: relative, owner: .root, mode: 0o600)
        return userUUID
    }

    private func ensureUIDAvailable() throws {
        let directory = disk.path(Provisioner.usersDirectory)
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) where file.hasSuffix(".plist") {
            let record = try disk.readPlist("\(Provisioner.usersDirectory)/\(file)")
            if (record["uid"] as? [String])?.first == String(user.uid) {
                throw CLIError("uid \(user.uid) is already used by \(file)")
            }
        }
    }

    private func addToGroups(userUUID: String) throws {
        for group in ["admin", "staff", "com.apple.access_ssh"] {
            let relative = "\(Provisioner.groupsDirectory)/\(group).plist"
            var record = try disk.readPlist(relative)
            if record.isEmpty {
                guard group == "com.apple.access_ssh" else {
                    throw CLIError("guest group \(group) is missing")
                }
                record = [
                    "generateduid": [UUID().uuidString.uppercased()],
                    "gid": [Provisioner.sshAccessGroupID],
                    "name": [group],
                    "passwd": ["*"],
                    "realname": ["Remote Login ACL"]
                ]
            }

            var users = record["users"] as? [String] ?? []
            if !users.contains(username) {
                users.append(username)
            }
            record["users"] = users

            var members = record["groupmembers"] as? [String] ?? []
            if !members.contains(userUUID) {
                members.append(userUUID)
            }
            record["groupmembers"] = members

            try disk.writePlist(record, to: relative, owner: .root, mode: 0o600)
        }
    }

    private func writeHome() throws {
        try disk.makeDirectory(home, owner: user, mode: 0o755)
        for directory in ["Library", "Library/Preferences", "Desktop", "Documents", "Downloads"] {
            try disk.makeDirectory("\(home)/\(directory)", owner: user, mode: 0o755)
        }
        try disk.write(Data(String(format: "0x%X:0x0:0x0\n", user.uid).utf8), to: "\(home)/.CFUserTextEncoding", owner: user, mode: 0o644)

        var globalPreferences = try disk.readPlist("\(home)/Library/Preferences/.GlobalPreferences.plist")
        globalPreferences["AppleKeyboardUIMode"] = 3
        try disk.writePlist(globalPreferences, to: "\(home)/Library/Preferences/.GlobalPreferences.plist", owner: user, mode: 0o600)

        var screensaver = try disk.readPlist("\(home)/Library/Preferences/com.apple.screensaver.plist")
        screensaver["askForPassword"] = 0
        screensaver["askForPasswordDelay"] = 0
        screensaver["idleTime"] = 0
        try disk.writePlist(screensaver, to: "\(home)/Library/Preferences/com.apple.screensaver.plist", owner: user, mode: 0o600)
    }

    private func markSetupAssistantDone() throws {
        try disk.write(Data(), to: "private/var/db/.AppleSetupDone", owner: .root, mode: 0o644)

        let seen: [String: Any] = [
            "DidSeeCloudSetup": true,
            "DidSeePrivacy": true,
            "DidSeeSiriSetup": true,
            "DidSeeTouchIDSetup": true,
            "DidSeeTrueToneSetup": true,
            "GestureMovieSeen": "none",
            "LastSeenBuddyBuildVersion": osBuild,
            "LastSeenCloudProductVersion": osVersion
        ]
        try disk.writePlist(seen, to: "\(home)/Library/Preferences/com.apple.SetupAssistant.plist", owner: user, mode: 0o600)

        var system = try disk.readPlist("Library/Preferences/com.apple.SetupAssistant.plist")
        system.merge(seen) { $1 }
        try disk.writePlist(system, to: "Library/Preferences/com.apple.SetupAssistant.plist", owner: .root, mode: 0o644)
    }

    private func configureAutologin() throws {
        var loginwindow = try disk.readPlist("Library/Preferences/com.apple.loginwindow.plist")
        var accountInfo = loginwindow["AccountInfo"] as? [String: Any] ?? [:]
        // A FirstLogins entry relaunches Setup Assistant on the next graphical login.
        accountInfo.removeValue(forKey: "FirstLogins")
        accountInfo["MaximumUsers"] = max(accountInfo["MaximumUsers"] as? Int ?? 1, 1)
        accountInfo["OnConsole"] = accountInfo["OnConsole"] as? [String: Any] ?? [:]

        loginwindow["AccountInfo"] = accountInfo
        loginwindow["autoLoginUser"] = username
        loginwindow["GuestEnabled"] = false
        loginwindow["lastUser"] = "loggedIn"
        loginwindow["lastUserName"] = username
        loginwindow["RecentUsers"] = [username]
        loginwindow["SHOWFULLNAME"] = false
        try disk.writePlist(loginwindow, to: "Library/Preferences/com.apple.loginwindow.plist", owner: .root, mode: 0o644)

        try disk.write(kcpassword(), to: "private/etc/kcpassword", owner: .root, mode: 0o600)
    }

    private func enableSSH() throws {
        let launchdState = "private/var/db/com.apple.xpc.launchd"
        try disk.makeDirectory(launchdState, owner: .root, mode: 0o755)
        try disk.write(Data(), to: "\(launchdState)/disabled.migrated", owner: .root, mode: 0o644)

        var disabled = try disk.readPlist("\(launchdState)/disabled.plist")
        disabled["com.openssh.sshd"] = false
        try disk.writePlist(disabled, to: "\(launchdState)/disabled.plist", owner: .root, mode: 0o644, format: .xml)
    }

    private func disableSleepAndLock() throws {
        var global = try disk.readPlist("Library/Preferences/.GlobalPreferences.plist")
        global["com.apple.autologout.AutoLogOutDelay"] = 0
        try disk.writePlist(global, to: "Library/Preferences/.GlobalPreferences.plist", owner: .root, mode: 0o644)

        let power: [String: Any] = [
            "AC Power": [
                "Automatic Restart On Power Loss": true,
                "DarkWakeBackgroundTasks": 0,
                "Disk Sleep Timer": 0,
                "Display Sleep Timer": 0,
                "System Sleep Timer": 0,
                "Wake On LAN": 1
            ],
            "SystemPowerSettings": [
                "Update DarkWakeBG Setting": true
            ]
        ]
        try disk.writePlist(power, to: "Library/Preferences/com.apple.PowerManagement.plist", owner: .root, mode: 0o644)
    }

    private func shadowHashData() throws -> Data {
        let iterations = 50_000
        var salt = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else {
            throw CLIError("cannot generate password salt")
        }

        var entropy = [UInt8](repeating: 0, count: 128)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.utf8.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
            UInt32(iterations),
            &entropy, entropy.count
        )
        guard status == kCCSuccess else {
            throw CLIError("password hashing failed (\(status))")
        }

        let shadow: [String: Any] = [
            "SALTED-SHA512-PBKDF2": [
                "entropy": Data(entropy),
                "iterations": iterations,
                "salt": Data(salt)
            ]
        ]
        return try PropertyListSerialization.data(fromPropertyList: shadow, format: .binary, options: 0)
    }

    // The plaintext is NUL padded to a multiple of 12 (always at least one NUL) before XOR,
    // otherwise loginwindow cannot unlock the login keychain and replaces it on every boot.
    private func kcpassword() -> Data {
        let key: [UInt8] = [0x7d, 0x89, 0x52, 0x23, 0xd2, 0xbc, 0xdd, 0xea, 0xa3, 0xb9, 0x1f]
        var plaintext = Array(password.utf8)
        plaintext.append(contentsOf: [UInt8](repeating: 0, count: 12 - plaintext.count % 12))
        return Data(plaintext.enumerated().map { $0.element ^ key[$0.offset % key.count] })
    }
}

func writeAuthorizedKeys(_ keys: Data, disk: GuestDisk, home: String, owner: GuestDisk.Owner) throws {
    try disk.makeDirectory("\(home)/.ssh", owner: owner, mode: 0o700)
    try disk.write(keys, to: "\(home)/.ssh/authorized_keys", owner: owner, mode: 0o600)
}
