# 9. Backup and restore

[← Contents](README.md)

All your data (medicines, stock, bills, customers, stockists, settings and staff) is kept in one
file on this computer. **If the computer is lost, stolen or its disk fails, the data goes with
it**, unless you have a backup somewhere else.

**Who can do this:** Owner (permission *Export or restore backups*). Others see *"Your role
can't export backups."*

The tiles at the top show **Storage** (on this device), **Records** (how many medicines and
invoices) and **Last backup**.

## Make a backup now

1. Go to **Backup & restore** (or press **Back up now** on the menu card).
2. **Encrypt with password** is on by default and recommended for patient data. Type the
   **Password** (at least 6 characters) and **Confirm password**.
3. Press **Back up now**. A progress bar runs, then *"Backup saved · rxdesk-backup-….rxbak"*.

> **Keep the password safe.** Without it, the backup can't be restored, and nobody can recover it.

The file is named like `rxdesk-backup-2026-11-16-1830.rxbak`. **Copy it off this computer**:
to a pen drive, an external disk, or another computer.

## Automatic backups

Under **Automatic backup**:

- **Back up automatically:** on by default.
- **Frequency:** **Daily**, **Weekly** or **Monthly**.
- **Folder:** `Documents/RxDesk/Backups` unless you choose another with **Change folder**.
  Choosing a folder on a USB or network drive keeps a copy away from this computer.
- **Run now** makes one immediately.

Automatic backups run **when RxDesk closes**, and when it **first opens on a day** if one is due.
The latest 30 are kept and older ones are removed.

> Automatic backups are **not** password-protected. Keep that folder private.

## Restore from a backup

Restoring **replaces** everything on this device with the backup's data.

1. Make sure no bill is being saved at the counter.
2. Press **Choose backup file…** and pick the `.rxbak` file.
3. If it is encrypted, enter its password and press **Continue**.
4. Read the confirmation (which file, how many medicines and invoices, when it was made) and
   press **Restore**.

Before restoring, RxDesk saves a **Safety** backup of today's data, so a wrong restore can be
undone. It checks that the file is complete and undamaged, and that it isn't from a newer version
of RxDesk. After restoring, RxDesk reopens the data and shows *"Restored from …"*.

**Moving to a new computer:** install RxDesk there, create an Owner account to get in, then
restore your latest backup. Staff accounts and PINs come back from the backup, so afterwards
everyone signs in with their usual PIN.

## Backup history

**History** lists each backup: **File** (with a lock icon when it has a password), **Created**,
**Size** and **Type** (**Manual**, **Auto** or **Safety**). Each row has a **Restore** button.
