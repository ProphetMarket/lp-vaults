TODO:

DONE:
- 20260910T182922 [implemented] command:change plan:20260910T181131-admin-role-removal-on-factory — Extended SC-REQH and FR-REQZ so that non-admin callers are rejected by addAdmin, removeAdmin, and renounceAdminRole
- 20260910T182922 [implemented] command:spec plan:20260910T181131-admin-role-removal-on-factory — Added addAdmin, removeAdmin, and renounceAdminRole scenarios (SC-5UJF to SC-5UJQ) and the acceptAdmin already-admin scenario (SC-5UJR) to close audit issue 6.8, including the pending-proposal clear from the design review
- 20260630T055731 [implemented] command:spec plan:20260630T060432-factory-delegated-auth — Added SC-FKD4 (operator rotation propagation) and SC-FKD5 (oracle rotation propagation) to verify factory role changes take effect on existing vaults
- 20260617T055202 [implemented] command:spec plan:20260617T055202-deploy-lp-vault-for-market — Factory role management: addOperator, removeOperator, setOracle, transferAdmin, acceptAdmin
