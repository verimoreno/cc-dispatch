# cleanup-laundry Branch Divergence Report

Generated: 2026-06-25

**Divergence:** `main` is **109 commits ahead** of `dev-branch`. `dev-branch` is **49 commits ahead** of `main`.

---

## 🟢 In PROD (main only — not in dev-branch)

| Feature / Fix | Summary |
|---|---|
| **RFID Inventário Cleanup** | Full RFID gun flow for Cleanup sweeps: Bluetooth SPP, lost-unit reactivation count, sorting_operator allowlist, gun lifecycle DB, prod APK for Sheila |
| **Reassign RFID Tag** | Staff can reassign a tag to a different client/item, with history |
| **Edit Manifesto Bug Fix** | Fix cage/session delete behind edit-manifest capability; enforce delete role check |
| **Cage Item Count in Expedition** | Show cage item count above kg (Jessica feedback) |
| **Reconciliation Perf Index** | `bucket_items(scanned_at)` index + sargable date filter |
| **Portal Inventory Scoping** | `visible_owners` fix — own-only → visible scoping; hide foreign-owned strays in Entrada |
| **Customer Portal Mixes Fix** | Fix for mixed items in reconciliation |

---

## 🔵 In STAGING (dev-branch only — not in main)

| Feature / Fix | Summary |
|---|---|
| **Nova Entrada Stepped Flow** | Multi-step weighing intake: category → cor → método; Cama→Quarto rename |
| **Stock Renting Dashboard** | Per-hotel linen stock dashboard (subcategoria + localização) + ideal config grid + auto-seed for unconfigured hotels |
| **Configurable Ticket Routing** | Workflow builder UI for Laura to configure routing rules (Phases 1–2) |
| **CSV Export — All Tables** | Full CSV export for finance feeds (accounting, billing, treasury) + all data tables |
| **Edit Expedition Manifests** | Laura's request: edit everything in an already-created manifest (incl. RFID cages) |
| **Group Stock Import (RFID)** | Import RFID linen to a group pool (not a single hotel); group owner selector |
| **Ticket Kanban Cap Fix** | Raise fetch cap 200→1000 (was hiding old open tickets on staging) |
| **PWA Cache Fix** | NetworkFirst nav so refresh picks up new deploys |
| **Reporting Day Alignment** | Operations dashboard uses ship-day (`shipped_at`) instead of delivery date |
| **Inline Ticket Edit** | Inline edits update the detail page instantly (no refetch lag) |
| **Note Author Fix** | Resolve note authors via profiles, not assignable-staff |

---

## 🖥️ Active Sessions on cc-host → What They're Doing

| Session | Branch | Status | Summary |
|---|---|---|---|
| **bug_reconciliaes** | `bug_reconciliações` | idle/just started | No transcript yet — session started Jun 23, no conversation recorded |
| **check_blocked_tickets** | `check_blocked_tickets` | ✅ concluded | Investigated hotel client Renata's ticket visibility. Verdict: data issue, not a bug — her tickets are all archived. Cleaned up. |
| **melhorar_entrada** | `melhorar_entrada` | ✅ fix done, not in prod | Stepped intake flow (Nova Entrada). QA found `backFromInput()` didn't clear scratch state — fixed. PR #283 **NOT yet in main**. |
| **issue_281** | `issue_281` | 🔄 in progress | Structurally linking "Pedir Correção de Manifesto" tickets to their expedition manifest. Analysis done, implementation pending. |
| **dashboard_stock** | `dev-branch` (worktree) | ✅ shipped to staging | Stock dashboard + 6 DB migrations on dev-branch. Not in prod yet. |
| **check_expedition_client** | `check_expedition_client` | ✅ concluded | 402 pieces with wrong "hotel atual" (Innkeeper vs Gat). Verdict: numbers are correct — stock vs. financial report measure different things. |
| **check_invoicing_error** | `fix_rfid_cage_billing_race` | ⚠️ fix done, not shipped | RFID cage billing race condition fixed + tested on branch, but **no PR to main**. Bug still live in prod. Highest priority: open PR. |
| **feat-hotel-portal** | `feat/hotel-portal` | 🔄 stalled | Session has no real work — user typed a bash command into chat. Hotel portal feature exists on the branch but session is effectively idle. |
| **cabine_change_states** | `cabine_change_states` | ✅ ready to merge | PR #268 (cabin state changes) confirmed all migrations pass on prod, rebased against main. **Ready to merge**. |
| **db_change_iventario** | `inventario_db_prod` | ⚠️ superseded | Inventory migrations here are a subset of `android_app_connect_db` which has fuller RLS hardening. Recommendation: discard this branch. |
| **edit_exhisting_tag** | `edit_exhisting_tag` | ✅ verification done | Confirmed "edit existing tag" (PR #283) is **NOT in prod** — PR still open, migration not in prod DB. |
| **fix_bug_edit_manifesto** | `fix_bug_edit_manifesto` | ✅ concluded | Suspicious expedition session on staging (backdated, null created_by). Verdict: test/seeded entry, not a real bug. Only on staging. |
| **cs_improvements** | `cs_improvements` | 🔄 in progress | Web Push notifications for CS staff (new ticket, new customer message, mixing >5%). Assessment phase — what exists vs. what needs building. |
| **edit_manifestos** | `hotfix/manifest-migration-reconcile` | 🔄 context compacted | Edit expedition manifests feature (Laura's request). Mid-implementation when context was compacted. |
| **add_clothe_togroup** | `add_clothe_togroup` | 🔄 redirected | User interrupted to ask about edit manifests feature. Implementation plan being scoped. |
| **ticket_routing** | `dev-branch` | 🔄 context compacted | Configurable ticket routing UI. Phase 1 built and under review. Context compacted. |
| **compare_lauraasks_with_current** | `docs/laura-portal-assessment` | ✅ concluded | Laura portal assessment complete. Only open item: `feat/hotel-portal` is staging-only, needs prod sign-off. |
| **dashboard_sync** | `fix/reporting-day-align-delivery-date` | ✅ shipped | Ship-day alignment for all 4 dashboard surfaces is in prod (PR #184). Stable, waiting for Laura feedback. |

---

## Key Actions

1. **`check_invoicing_error`** — RFID cage billing race fix exists but has no PR to main. Open the PR now, this bug is live in prod.
2. **`cabine_change_states`** — PR #268 is ready to merge, all checks pass.
3. **`melhorar_entrada` / `edit_exhisting_tag`** — Both features done on branches, need PRs to reach their target (main or dev-branch).
4. **`feat/hotel-portal`** — Session is stalled/idle. If the feature is ready on staging, someone needs to own the prod sign-off.
5. **`db_change_iventario`** — Branch is superseded by `android_app_connect_db`. Can be killed.
6. **`dev-branch` → `main` sync** — 49 commits of staging work (stock dashboard, CSV export, ticket routing, edit manifests) haven't been promoted. Plan a staging → prod release.
