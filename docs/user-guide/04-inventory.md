# 4. Inventory

[← Contents](README.md)

Inventory lists every medicine with its stock kept **batch by batch**: each batch has its own
batch number, expiry and quantity.

**Who can see it:** everyone.
**Who can change it** (add medicines, receive stock, pack sizes): Owner and Pharmacist
(permission *Change stock, prices and batches*).

## Views

The tabs across the top are saved views, each with a count:

| View | Shows |
|---|---|
| **All items** | Every medicine |
| **Low stock** | Saleable stock at or below the medicine's reorder level |
| **Expiring ≤ Nd** | Medicines with a batch expiring inside your warning window (90 days unless changed in Settings › Inventory) |
| **Out of stock** | Nothing saleable left |
| **Dead stock** | In stock but not sold for 90 days (changeable in Settings › Inventory) |

## Search, filter and sort

- **Search** by medicine name, salt, batch number, barcode or HSN code.
- **Category** and **Maker** filters narrow the list.
- Click the **Medicine**, **Nearest expiry**, **Saleable stock** or **MRP** column heading to
  sort. Click it again to reverse the order.
- Choose 25, 50 or 100 rows per page and move between pages at the bottom.
- **Export** saves the current list as a spreadsheet (CSV) file.

## Reading a row

**Medicine** (name, Rx badge, salt · pack · number of batches) · **Maker** · **Category** ·
**Nearest expiry** (red if a month or less, amber if inside the warning window) · **Saleable
stock** (bar and number) · **MRP** · **Rack** · **Status** · **Receive** button.

For medicines sold loose, stock reads like **12 strips + 4 tabs**.

### Batches and details

Click a row (or **Show batches**) to open it. You'll see:

- **The batch table:** **Batch**, **Expiry**, **Qty**, **MRP** and a **Note** for each batch:
  - **Sell first (FEFO)**: the batch billing will pick first
  - **Near expiry**: inside your warning window
  - **Expired · return to supplier**: can't be sold. Send it back with
    [Return / credit note](05-purchases.md#return-stock-or-record-a-credit-note).
  - **Sold out**: nothing left in this batch
  - **OK**
- **Details:** barcode, HSN, GST rate, reorder level and when the medicine was last sold.
- **GET FROM:** the stockists this medicine comes from, with phone numbers, the MR and the last
  received date (from the [stockist directory](05-purchases.md#stockists-directory-damdawi-lak-na)).
- **Sold whole only** or **10 tabs per strip · sold loose**, with a **Sell loose…** or **Change** button.

## Add a medicine

1. Press **Add medicine**.
2. Fill in:
   - **Medicine name**, e.g. *Paracetamol 500 mg Tablet*. Required.
   - **Salt / composition**, e.g. *Paracetamol 500 mg*. Billing uses it to suggest substitutes, so
     keep it consistent.
   - **Manufacturer** (required) and **Pack**, e.g. *Strip of 10*.
   - **Category**: Tablet, Capsule, Syrup, Injection, OTC, Topical and so on.
   - **Tablets per strip** (or **Capsules per strip** / **Units per pack**). For tablets and
     capsules it's filled in from the pack, e.g. "Strip of 10" → 10. Enter **1** if you only sell whole packs.
   - **Schedule**: **None**, **H** or **H1**.
   - **Barcode**: scan or type it.
   - **First batch no.**, **Expiry** (MM/YYYY) and **Opening qty**. For strips, the opening qty
     is typed in strips.
   - **Reorder level**: when stock falls to this many packs, the medicine shows as low. It starts
     at the default from Settings.
   - **MRP (₹, incl. GST)**: the MRP printed on the pack, per strip / pack. Required.
   - **GST rate**: **0%**, **5%**, **12%** or **18%**.
   - **HSN code** (e.g. 3004) and **Rack / shelf**.
3. Press **Save medicine**.

## Receive stock (without a stockist invoice)

Use this for quick additions. To record a stockist's invoice, its amount and what you owe, use
[Purchases › Receive invoice](05-purchases.md#receive-a-stockist-invoice) instead.

1. Press **Receive** on the medicine's row.
2. Enter **Batch no.**:
   - **An existing batch number** adds to that batch (*"Adding to existing batch …"*).
   - **A new batch number** creates a new batch. Enter its **Expiry** (MM/YYYY).
3. Enter **Quantity received**, in strips for loose-sold medicines. The **+10**, **+25**,
   **+50** and **+100** buttons fill in that quantity.
4. Press **Add to stock**.

Check the expiry before you receive a batch here. Expired stock can never be sold, so it has no
place in stock. (Purchases › Receive invoice refuses an expiry that has already passed.)

## Sell loose tablets (set the pack size)

A medicine can be sold by the tablet once you tell RxDesk how many tablets make a strip.

1. Open the medicine's row and press **Sell loose…** (or **Change**).
2. Enter the number of tablets (or capsules / units) per strip. RxDesk shows what the stock
   becomes, e.g. *"Stock becomes 120 tabs"*, and that the MRP stays per strip.
3. Press **Save**.

- Loose tablets are charged pro-rata: MRP × tablets ÷ tablets per strip, rounded down to the paisa.
- Set **1** to go back to selling whole packs only.
- The size can't be changed while any batch holds loose tablets (part of a strip). Sell or
  adjust those first.
- The reorder level stays counted in strips.

## Reorder levels

Each medicine has a reorder level, counted in packs. A medicine is **low** when its saleable
stock is at or below that level. It then shows in **Low stock**, on the Dashboard and in
**Purchases › New order › Add low-stock items**.

To set reorder levels from real sales, use the **Consumption register** button on this screen.
It opens the [Inventory Management Register](08-reports.md#inventory-management-register),
which can apply suggested reorder levels for many medicines at once.
