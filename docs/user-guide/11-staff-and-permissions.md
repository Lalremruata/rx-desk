# 11. Staff and permissions

[← Contents](README.md)

Each person who uses the counter has their own account and 4-digit PIN. Bills record who made
them. Everything here is in **Settings › Staff & roles**, and only the Owner can change it.

## Roles

- **Owner:** has every permission, always. This can't be turned off.
- **Pharmacist** and **Cashier:** have the permissions ticked for them in the table below. The
  Owner can change them.

## Add a staff member

1. Go to **Settings › Staff & roles** and press **Add staff**.
2. Enter the **Name**, choose the role (**Owner**, **Pharmacist** or **Cashier**), and type a
   **4-digit PIN**.
3. Press **Add**.

The new person appears on the lock screen at once.

> **Tip:** consider a second Owner account (for a partner, or kept sealed in an envelope). An
> Owner's PIN can only be reset by an Owner. With two Owner accounts, a forgotten PIN is never a
> dead end.

## Change a role, reset a PIN, disable an account

Each person's row shows their name, role, and whether they're **Active** or **Disabled**.

- **Change role:** pick a new role from the drop-down. The change applies straight away.
- <a id="reset-a-pin"></a>**Reset PIN:** press **Reset PIN**, type the new 4-digit PIN and press
  **Save PIN**. Use this when someone forgets their PIN.
- **Disable:** turn the switch off when someone leaves, so they can no longer sign in. Their past
  bills are unchanged. Turn the switch back on to re-enable them.

Staff accounts are never deleted, so the record of who made each bill stays complete.

## What each role can do

The table **What each role can do** sets the permissions. Click a box to switch it on or off for
Pharmacist or Cashier, then press **Save changes**. These are the starting settings:

| Permission | Owner | Pharmacist | Cashier | What it covers |
|---|:-:|:-:|:-:|---|
| **Sell Schedule H / H1 medicines** | ✓ | ✓ | — | Billing prescription medicines |
| **Give more than 5% discount** | ✓ | ✓ | — | Discount chips above 5% |
| **Edit or cancel a saved bill** | ✓ | ✓ | — | **Cancel bill** in Invoices |
| **Change stock, prices and batches** | ✓ | ✓ | — | Add medicine, receive stock, pack sizes, orders, receiving invoices, stockist directory, applying reorder levels |
| **See sales register and reports** | ✓ | ✓ | — | Sales register and the Inventory Management Register |
| **Export or restore backups** | ✓ | — | — | Backup & restore |
| **Change settings** | ✓ | — | — | All of Settings |
| **Record supplier payments** | ✓ | — | — | Stockist payments, credit notes, opening balances, voids, stockist terms, paid on delivery. Returns to a stockist also need *Change stock*. |
| **Accept returns / issue credit notes** | ✓ | ✓ | — | **Return items** in Invoices |
| **Sell on credit (udhaar)** | ✓ | ✓ | — | The **Credit** payment mode |
| **Collect customer payments** | ✓ | ✓ | ✓ | Receiving payments, adding or editing customers |
| **Set credit limits, opening dues, void payments** | ✓ | — | — | Customer credit control |

Some things are **Owner only, whatever the table says**:

- **Returns outside the return window.** A bill older than the window in Settings › Billing &
  tax can only be returned by an Owner.
- **Allowing a credit bill over the customer's limit.** An Owner at the counter confirms it.
  Anyone else needs an Owner to type their **Owner PIN** into the box that appears.

## When something isn't allowed

- A whole screen you can't use shows *"Not available for your role"*. It names the permission
  and says to ask the owner to change it in Settings › Staff & roles.
- A single action that isn't allowed shows a short message, e.g. *"Your role can't sell on
  credit"*.
