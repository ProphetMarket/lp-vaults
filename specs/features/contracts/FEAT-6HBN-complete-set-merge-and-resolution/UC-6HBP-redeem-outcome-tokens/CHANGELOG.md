TODO:

DONE:
- 20260914T142913 [implemented] command:spec plan:20260914T142629-redemption-after-resolution-r13 — Added the use case: the Oracle redeems the vault outcome tokens after the market resolves, and that call is the switch that values every later payout at the stored payout (audit-fix step R13, decision K3). Reuses the reserved IDs UC-6HBP, SC-6HCD to SC-6HCI, FR-6HC4 to FR-6HC7, NFR-6HC8, and ADR-6HCK, and adds SC-CYS6 (a numerator above 2^128 leaves the switch off), FR-CYS2 (the numerator bound), and NFR-CYS3 (the gas bound). Two departures from the R13 step text, chosen by the user on 2026-09-14: the switch is the Oracle call and not a live read, and the redemption reverts while Active. Source: exploration 20260914T140852-redemption-after-resolution-r13.
