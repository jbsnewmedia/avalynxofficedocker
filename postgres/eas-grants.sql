-- Least-privilege grants for the ActiveSync (EAS) database role.
--
-- Idempotent; run via `./core.sh grant-eas` (psql variable :role). The office
-- entrypoint applies the same grants automatically after every migration run,
-- so this file is only needed when the grants have to be re-applied manually.
SELECT set_config('avalynxoffice.eas_role', :'role', false);

DO $$
DECLARE
    r text := current_setting('avalynxoffice.eas_role');
    t text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        RAISE EXCEPTION 'role % does not exist (created by postgres/init/01-eas-role.sh on a fresh volume)', r;
    END IF;
    EXECUTE format('GRANT USAGE ON SCHEMA public TO %I', r);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', r);
    EXECUTE format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO %I', r);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO %I', r);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO %I', r);
    -- Mail, address book and calendar tables written by the EAS service.
    FOREACH t IN ARRAY ARRAY[
        'email', 'email_folder', 'email_address_link', 'email_body_link', 'email_attachment_link',
        'body', 'attachment', 'address', 'account_address', 'folder', 'account_folder',
        'calendar_event'
    ] LOOP
        IF to_regclass('public.' || quote_ident(t)) IS NOT NULL THEN
            EXECUTE format('GRANT INSERT, UPDATE, DELETE ON TABLE public.%I TO %I', t, r);
        END IF;
    END LOOP;
    -- Column-restricted updates: inbox folder detection and the
    -- last-authentication timestamp of a user.
    IF to_regclass('public.account') IS NOT NULL THEN
        EXECUTE format('GRANT UPDATE (inbox_folder_id) ON TABLE public.account TO %I', r);
    END IF;
    IF to_regclass('public.app_user') IS NOT NULL THEN
        EXECUTE format('GRANT UPDATE (last_auth_at) ON TABLE public.app_user TO %I', r);
    END IF;
    IF to_regclass('public.app_user_app_password') IS NOT NULL THEN
        EXECUTE format('GRANT UPDATE (last_used_at) ON TABLE public.app_user_app_password TO %I', r);
    END IF;
END
$$;
