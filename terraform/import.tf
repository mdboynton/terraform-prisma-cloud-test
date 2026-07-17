# Import blocks adopting pre-existing live tenant artifacts into Terraform state.
#
# NOTE (tuan_test branch): all real-tenant import blocks have been removed for the
# disposable local test tenant. The test config (config/teams.yaml) defines a
# single "tuan-test" team whose artifacts do not exist yet, so nothing is imported
# here — everything is a planned creation. Restore the real import blocks from the
# main branch before running against the production tenant.
