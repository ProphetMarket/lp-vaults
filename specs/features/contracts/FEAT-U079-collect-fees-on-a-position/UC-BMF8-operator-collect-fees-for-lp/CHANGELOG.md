TODO:

DONE:
- 20260913T210551 [implemented] command:spec plan:20260913T210232-lp-exit-claim-model-merge-r9 — Added the use case: the Operator relays the owner key's signed CollectIntent(address lp,uint256 positionId,uint256 nonce,uint256 deadline) through collectFor, verified with _verifySafeOwnerSignature and compared with position.owner, with its own record keyed by the struct hash, a nonce because a collect repeats, and a deadline (audit-fix step R9, decision C3). Scenarios SC-BMFG to SC-BMFM and SC-BMG6, requirements FR-BMF9, FR-BMFA, FR-BMFB, and NFR-BMFC. Source: exploration 20260913T154424-lp-exit-claim-model-merge-r9.
