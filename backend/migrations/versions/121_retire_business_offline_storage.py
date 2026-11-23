"""Remove the abandoned business replica schema, preserving online records."""

from alembic import op

revision = "121"
down_revision = "120"
branch_labels = None
depends_on = None


def upgrade():
    if op.get_context().dialect.name != "postgresql":
        return
    op.execute(r"""
DO $$
DECLARE
    item record;
    objects text;
    target_schema text := current_schema();
BEGIN
    -- Cancel capture on live tables first. Limit all catalog queries to the
    -- current application schema; never cascade to an unrelated object.
    FOR item IN
        SELECT t.tgname AS trigger_name, c.relname AS table_name
        FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = target_schema AND NOT t.tgisinternal
          AND left(t.tgname::text, 14) = 'business_sync_'
    LOOP
        EXECUTE format('DROP TRIGGER %I ON %I.%I',
                       item.trigger_name, target_schema, item.table_name);
    END LOOP;

    SELECT string_agg(format('%I.%I(%s)', n.nspname, p.proname,
                            pg_get_function_identity_arguments(p.oid)), ', ')
    INTO objects
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = target_schema AND p.prokind = 'f'
      AND left(p.proname::text, 14) = 'business_sync_';
    IF objects IS NOT NULL THEN EXECUTE 'DROP FUNCTION ' || objects; END IF;

    SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ')
    INTO objects
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = target_schema AND c.relkind IN ('r', 'p')
      AND c.relname::text = ANY(ARRAY[
        'business_sync_heads', 'business_sync_operations', 'business_sync_changes',
        'business_sync_devices', 'business_sync_device_events', 'business_sync_permission_scopes',
        'business_sync_protocol', 'business_sync_invoice_pending', 'business_sync_checkout_pending',
        'business_sync_return_pending', 'business_sync_expense_pending', 'business_sync_cheque_pending',
        'business_sync_accounting_pending', 'business_sync_transfer_pending',
        'business_sync_branch_pending', 'business_sync_member_pending'
      ]);
    IF objects IS NOT NULL THEN EXECUTE 'DROP TABLE ' || objects; END IF;
END $$;
""")


def downgrade():
    raise RuntimeError("Retired business replica data cannot be restored by downgrade.")
