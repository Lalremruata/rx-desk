# 12. How RxDesk works, FAQ and glossary

[← Contents](README.md)

## Rules RxDesk always follows

- **MRP includes GST.** Tax is worked out *from* the MRP and never added on top.
- **Expired batches can never be sold.** No setting turns this off.
- **Bills are never deleted.** A wrong bill is cancelled, or items are returned with a credit
  note. Both stay on record.
- **Invoice numbers have no gaps.** Each number is given out when the bill is saved, in order,
  and is never reused. A cancelled bill keeps its number.
- **Stock can't go below zero**, unless the Owner turns on *Allow billing more than stock*.
- **Saving is all or nothing.** A bill, its stock change and its totals are saved together. If
  anything fails, nothing is saved.
- **Bills remember what was sold.** Each bill keeps the medicine name, salt, maker, HSN, schedule,
  batch, expiry, MRP and GST rate *as they were*. Changing a price later doesn't change old
  bills or reports.
- **Nothing leaves the device.** RxDesk makes no internet connections.

## How GST is worked out

For each line of the bill:

1. **Amount at MRP** = MRP × quantity. For loose tablets: MRP × tablets ÷ tablets per strip,
   rounded down to the paisa.
2. **Discount** = amount × discount %, rounded to the paisa. With a flat **₹** discount, the
   rupees are shared across the lines in proportion to each line's amount, to the paisa; the
   shares add up exactly to the ₹ typed.
3. **Net** = amount − discount.
4. **Taxable value** = net × 100 ÷ (100 + GST rate), rounded to the paisa.
5. **GST** = net − taxable value.

The bill's totals are the lines added up. GST is split equally into **CGST** and **SGST**; if it
doesn't split evenly, the extra paisa goes on SGST. With rounding on, the total is rounded to the
nearest rupee and the difference shows as **Round off**.

**Example.** 2 strips at MRP ₹45.50, GST 12%, 10% discount:

| Step | Amount |
|---|---|
| Amount at MRP: 2 × ₹45.50 | ₹91.00 |
| Discount 10% | − ₹9.10 |
| Net | ₹81.90 |
| Taxable value: ₹81.90 × 100 ÷ 112 | ₹73.13 |
| GST: ₹81.90 − ₹73.13 | ₹8.77 → CGST ₹4.38 + SGST ₹4.39 |
| Round off | + ₹0.10 |
| **Net payable** | **₹82.00** |

If the store is not GST registered (Settings › Billing & tax), bills print as **BILL OF SUPPLY**
with no GST breakup.

## Invoice numbers and the financial year

- The financial year runs **1 April – 31 March**. The year 2026-27 is written `26-27`.
- With **Include financial year** on, numbers look like `INV/26-27/00412` and start again at
  `00001` on 1 April. With it off, they keep counting.
- Credit notes have their own series (`CN/26-27/00001`).
- Changing the number format in Settings only affects new bills.

## Frequently asked questions

**The bill didn't print.**
Open **Settings › Invoice**: check the paper size and the **Counter printer**, and press **Test
print**. Check that the printer is switched on and has paper. To print the bill again, find it in
**Invoices** and press **Print**. Thermal printers need their own driver installed in Windows.

**I need to reprint an old bill.**
**Invoices** → search by bill number, customer or phone (choose a wider date range if needed) →
**Print** or **Download PDF**.

**A customer wants to return something.**
**Invoices** → find the bill → **Return items**. See
[Invoices and returns](06-invoices-and-returns.md#return-items-credit-note).

**"Return items" is greyed out or missing.**
One of these applies:
- The bill is older than the return window, so only the Owner can return it.
- Your role doesn't have *Accept returns*.
- The bill was cancelled.
- Everything on it has already been returned.

Schedule H / H1 lines can never be returned.

**"Cancel bill" won't work.**
Only an ordinary paid bill with no returns can be cancelled, and only by someone with *Edit or
cancel a saved bill*. If items were returned already, use **Return items** for the rest.

**I made a mistake on a saved bill.**
Bills can't be edited. Cancel it, if allowed, and make a new one. Or return the wrong items and
bill the right ones.

**The customer is over their credit limit.**
The Owner has to allow the bill: at the counter, or by typing the Owner PIN. Or take part of
the payment now with **Paid now**. Or raise the customer's limit in **Customers › Edit**.

**A medicine shows stock, but I can't bill it.**
The remaining batches have probably expired, which shows as **Expired · blocked** in the batch
list. Return them to the stockist from **Purchases › Dues › Statement › Return / credit note**.

**Stock is wrong for a batch.**
Open the medicine in **Inventory**, press the pencil button on the batch and type the
**Counted quantity**, with a reason (Count correction, Damaged, Lost / theft or Other). To send
stock back to the stockist, use **Purchases › Dues › Statement › Return / credit note**
instead, so their credit is recorded too.

**A batch number or expiry was typed wrong.**
Use **Edit batch** (the pencil on the batch row) to fix it. An expiry that has already passed
is locked, because expired stock can never be sold.

**The MRP of a medicine changed.**
When new stock arrives at a new MRP, receive it as a **new batch** and type the new MRP on the
line. The medicine's MRP moves to the new one, and the older packs keep selling at their own
printed MRP. To fix an MRP that was typed wrong, use **Edit batch** (one batch) or **Edit
medicine** with **Also change the N batches** on. Saved bills always keep their old price.

**The stockist gave free goods (10 + 1).**
On the receipt line, type 10 in **Qty received** and 1 in **Free**. All 11 go into stock, and the
cost per strip is worked out over the 11.

**We stopped selling a medicine.**
Use **Hide medicine**. It leaves search and the stock lists but nothing is deleted; bring it
back from **Inventory › Hidden**.

**Stock arrived in boxes. How many strips is that?**
On the receipt line, choose **Box** and type **Strips per box**. RxDesk multiplies it out and
remembers the number for that medicine (see
[Receiving in boxes](05-purchases.md#receiving-in-boxes-strips-per-box)).

**Somebody forgot their PIN.**
The Owner sets a new one in **Settings › Staff & roles › Reset PIN**. An Owner's PIN can only be
reset by another Owner account, so keep the Owner PIN safe.

**We're moving to a new computer.**
Make a backup on the old one. On the new one, install RxDesk, create an Owner account, then
**Backup & restore › Choose backup file…**. See [Backup and restore](09-backup-and-restore.md).

**What do I give the accountant for GST?**
**Sales register › GST summary by HSN (last month) › Export Excel**. For a full listing, export
the **Lines** view for the month.

## Glossary

| Term | Meaning |
|---|---|
| **Batch** | One lot of a medicine from the maker, with its own batch number, expiry and quantity |
| **FEFO** | First Expiry, First Out: sell the batch that expires soonest first |
| **MRP** | Maximum Retail Price printed on the pack. It includes GST. |
| **Taxable value** | The price without GST |
| **CGST / SGST** | The central and state halves of GST |
| **HSN** | Harmonised System of Nomenclature: the tax code for a kind of goods (most medicines are 3003 / 3004) |
| **GSTIN** | Your 15-character GST registration number |
| **Bill of supply** | The bill issued by a store that isn't GST registered. It has no GST breakup. |
| **Credit note** | A document that reverses all or part of a bill, for a sales return. Stockists also give you credit notes. |
| **DL 20B / 21B** | Retail drug licence forms whose numbers must be printed on bills |
| **Schedule H / H1** | Prescription-only medicines. H1 sales are recorded in a register. |
| **Schedule X** | Tightly controlled medicines (mostly psychotropic) with extra record-keeping rules. They can't be sold from RxDesk. |
| **Udhaar / khata** | Selling on credit, written in the customer's account |
| **Dues** | What a customer owes the store, or what the store owes a stockist |
| **Advance / on account** | Money paid in advance, kept to settle the next bill |
| **Credit days** | How many days a stockist allows before a bill is due |
| **Closed short** | An order line where the stockist won't send the rest |
| **Damdawi lak na** | "Where to get medicines": your stockist directory sheet |
| **MR** | Medical Representative of a pharmaceutical company |
| **Strips per box** | How many strips (or packs) come in one stockist box. Used when receiving in boxes. |
| **Reorder level** | When stock falls to this many packs, the medicine shows as low |
| **Dead stock** | Stock that hasn't sold for a long time (90 days unless changed) |
| **Lead time** | How many days a stockist takes to deliver after you order |
