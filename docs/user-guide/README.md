# RxDesk user guide

RxDesk is the pharmacy counter app for your store. It handles billing, batch-wise stock and
expiry, GST invoices, purchases and stockist dues, customer credit (udhaar), sales reports and
backups. Everything stays on this computer or tablet. RxDesk does not need the internet, and
nothing is sent anywhere.

This guide is for everyone who uses RxDesk: the Owner and the counter staff (Pharmacists and
Cashiers).

## How to read this guide

- Each page covers one part of the app, in the same order as the menu on the left of the screen.
- Button and field names are written in **bold**, exactly as they appear on screen.
- `Keys` you press are written like `F10`.
- **Who can do this** says which roles can use a feature with the standard settings. The Owner can
  change what Pharmacists and Cashiers are allowed to do (see
  [Staff and permissions](12-staff-and-permissions.md)).

| Role | In short |
|---|---|
| **Owner** | Can do everything. Sets up the store, staff, prices, payments and backups. |
| **Pharmacist** | Bills (including Schedule H / H1), returns, credit sales, stock and purchases, reports. |
| **Cashier** | Bills ordinary medicines and collects customer payments. |

## Contents

1. [Getting started](01-getting-started.md): installing on Windows, first launch, PIN login, the screen layout, first-day setup, keyboard shortcuts
2. [Billing](02-billing.md): searching, batches, loose tablets, batch-wise MRP, discounts (chips, custom % or ₹), prescriptions, payment, credit bills, holding a bill (`F6`), B2B bills with the buyer's GSTIN, saving and printing
3. [Dashboard](03-dashboard.md): today's numbers, sales charts, what needs attention
4. [Inventory](04-inventory.md): stock by batch and expiry, adding, editing and hiding medicines, correcting batches, receiving stock, loose selling
5. [Purchases](05-purchases.md): order book, receiving stockist invoices (free goods, rate / discount / GST, batch MRP, boxes → strips per stockist), stockist dues and payments, the stockist directory
6. [Invoices and returns](06-invoices-and-returns.md): finding and reprinting bills, cancelling, sales returns and credit notes
7. [Customers and credit](07-customers-and-credit.md): udhaar, customer dues, payments and statements
8. [Day close](08-day-close.md): the cash that should be in the drawer, paid-outs, counting and closing the day
9. [Reports](09-reports.md): the Sales register, GST and Schedule H registers, GSTR-1 export, the Inventory Management Register
10. [Backup and restore](10-backup-and-restore.md): keeping your data safe
11. [Settings](11-settings.md): every setting explained
12. [Staff and permissions](12-staff-and-permissions.md): staff accounts, PINs, roles
13. [How RxDesk works, FAQ and glossary](13-how-it-works-and-faq.md): GST maths, invoice numbers, common questions

## A normal day at the counter

1. **Open RxDesk** and enter your PIN. If a backup is due, RxDesk makes it on its own.
2. **Check the [Dashboard](03-dashboard.md)**: low stock, medicines about to expire, overdue
   stockist bills and customer dues.
3. **Bill customers** on the [Billing](02-billing.md) screen. Search, pick the batch, then press
   `F10` to save and print.
4. **When stock arrives**, receive the stockist's invoice in [Purchases](05-purchases.md). The
   stock is added to the right batches, and the bill goes on that stockist's dues.
5. **Need to order?** Open **Purchases › New order** and choose **Add low-stock items**.
6. **When a customer pays their dues**, go to [Customers](07-customers-and-credit.md) and use
   **Receive**.
7. **At closing**, open [Day close](08-day-close.md): count the cash drawer, record what was
   paid out, and close the day. Check the day's total on the Dashboard or in the
   [Sales register](09-reports.md). Lock the counter. RxDesk makes the automatic backup when it
   closes. Every so often, copy the backup folder to a pen drive or another computer (see
   [Backup and restore](10-backup-and-restore.md)).
