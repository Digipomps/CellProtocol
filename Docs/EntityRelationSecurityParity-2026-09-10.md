# Unreleased EntityRelation security parity

This focused branch starts at audit HEAD `4096760`. EntityRelationRecordV1 is
not present on the security release's origin/main base `cde2e0a`. Apply this
patch when integrating the relation feature; do not merge the entire feature
history into main merely to obtain this fix.

Vapor now invokes the existing shared CellBase relation validator for direct
and batch mutations, and exposes the same owner-only value-free relation schema
as Apple. The tests exercise real EntityAnchor Cells on both hosts: direct-write
denial, wrong schema, keypath/ID mismatch, raw address rejection, malformed record,
metadata-only event content rejection, valid write and restart.

`/private/tmp/cp-security-relation-parity-verified.log`: 19 tests, zero failures.
Command: private-cache `Scripts/haven-swiftpm.sh ... test
--disable-automatic-resolution --jobs 4 --filter
'EntityRelationHostParityTests|EntityRelationRecordV1Tests|VaporCellRuntimeReadinessContractTests'`.
All newly created data and identifiers in the host tests are synthetic.
