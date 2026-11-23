--
-- PostgreSQL database dump
--

\restrict QA0kKf92rzhSNUAKfF5dKazXyOIAjr3U2SqFifXacpcF0rvcMhBlgsZlxMfP4rt

-- Dumped from database version 18.6 (Ubuntu 18.6-0ubuntu0.26.04.1)
-- Dumped by pg_dump version 18.6 (Ubuntu 18.6-0ubuntu0.26.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.accounts (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    code character varying(20) NOT NULL,
    name character varying(200) NOT NULL,
    name_ar character varying(200),
    type character varying(20) NOT NULL,
    parent_id uuid,
    is_active boolean DEFAULT true,
    balance numeric(12,2) DEFAULT '0'::numeric,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: admin_exchange_rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_exchange_rates (
    id uuid NOT NULL,
    currency_code character varying(20) NOT NULL,
    base_currency character varying(10) NOT NULL,
    rate_type character varying(20),
    buy_rate double precision NOT NULL,
    sell_rate double precision NOT NULL,
    average_rate double precision NOT NULL,
    source character varying(50),
    provider character varying(100),
    is_active boolean,
    changed_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: admin_operations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_operations (
    id uuid NOT NULL,
    bank_account_id uuid,
    bank_name character varying(200),
    type character varying(20),
    amount numeric(14,2) NOT NULL,
    currency character varying(10),
    description text,
    person_name character varying(200),
    created_by uuid,
    created_at timestamp with time zone
);


--
-- Name: admin_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_permissions (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    resource character varying(100) NOT NULL,
    can_create boolean,
    can_read boolean,
    can_update boolean,
    can_delete boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: agent_analytics_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_analytics_events (
    id uuid NOT NULL,
    org_id uuid NOT NULL,
    user_id uuid NOT NULL,
    event_type character varying(32) NOT NULL,
    tool_name character varying(128),
    success boolean,
    latency_ms integer,
    error_type character varying(64),
    question text,
    rounds integer,
    tool_count integer,
    tool_failures integer,
    created_at timestamp with time zone
);


--
-- Name: alembic_version; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.alembic_version (
    version_num character varying(32) NOT NULL
);


--
-- Name: app_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_config (
    key character varying(100) NOT NULL,
    value_encrypted text NOT NULL,
    updated_at timestamp with time zone
);


--
-- Name: app_notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_notifications (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    user_id uuid,
    source_notif_id uuid,
    type character varying(30),
    title character varying(300) NOT NULL,
    message text,
    action character varying(100),
    action_payload text,
    is_system boolean,
    is_read boolean,
    created_at timestamp with time zone,
    domain character varying(20) DEFAULT 'main'::character varying NOT NULL,
    event_id character varying(200),
    route character varying(200),
    image_url text
);


--
-- Name: attendances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attendances (
    id uuid NOT NULL,
    employee_id uuid NOT NULL,
    date date NOT NULL,
    check_in timestamp with time zone,
    check_out timestamp with time zone,
    status character varying(20),
    notes text,
    created_by uuid,
    created_at timestamp with time zone
);


--
-- Name: bank_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bank_accounts (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    bank_name character varying(200) NOT NULL,
    account_name character varying(200) NOT NULL,
    account_number character varying(100) NOT NULL,
    iban character varying(50),
    balance numeric(12,2) DEFAULT '0'::numeric,
    currency character varying(10) DEFAULT 'SAR'::character varying,
    is_active boolean DEFAULT true,
    is_deleted boolean DEFAULT false,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    account_type character varying(20) DEFAULT 'checking'::character varying NOT NULL,
    branch_id uuid,
    bank_group_key character varying(120)
);


--
-- Name: bank_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bank_transactions (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    bank_account_id uuid NOT NULL,
    date timestamp with time zone,
    description text DEFAULT ''::text,
    tx_type character varying(40) NOT NULL,
    amount numeric(12,2) NOT NULL,
    running_balance numeric(12,2) DEFAULT '0'::numeric,
    reference text,
    is_deleted boolean DEFAULT false,
    created_at timestamp with time zone,
    currency character varying(10) DEFAULT 'SAR'::character varying NOT NULL
);


--
-- Name: branch_invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.branch_invitations (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    invited_user_id uuid NOT NULL,
    invited_by uuid,
    identifier_type character varying(10) DEFAULT 'code'::character varying NOT NULL,
    identifier character varying(120),
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    permissions text DEFAULT '{}'::text NOT NULL,
    can_transfer boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone,
    expires_at timestamp with time zone,
    responded_at timestamp with time zone
);


--
-- Name: branch_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.branch_members (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    branch_ids text DEFAULT '[]'::text NOT NULL,
    permissions text DEFAULT '{}'::text NOT NULL,
    per_branch text DEFAULT '{}'::text NOT NULL,
    all_branches boolean DEFAULT false NOT NULL,
    can_transfer boolean DEFAULT false NOT NULL,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    invited_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    scope_valid_after timestamp with time zone
);


--
-- Name: branch_stock; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.branch_stock (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    product_id uuid NOT NULL,
    quantity numeric(14,3) NOT NULL,
    avg_cost numeric(14,4) NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: branch_transfer_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.branch_transfer_items (
    id uuid NOT NULL,
    transfer_id uuid NOT NULL,
    from_product_id uuid,
    to_product_id uuid,
    from_unit_id uuid,
    to_unit_id uuid,
    unit_name character varying(50),
    from_quantity numeric(18,4) DEFAULT '0'::numeric NOT NULL,
    to_quantity numeric(18,4) DEFAULT '0'::numeric NOT NULL,
    base_quantity numeric(18,4) DEFAULT '0'::numeric NOT NULL,
    factor numeric(18,6) DEFAULT '1'::numeric NOT NULL,
    unit_cost numeric(18,6) DEFAULT '0'::numeric NOT NULL,
    total_cost numeric(18,4) DEFAULT '0'::numeric NOT NULL,
    currency character varying(10),
    reversed_quantity numeric(18,4) DEFAULT '0'::numeric NOT NULL,
    created_at timestamp with time zone,
    target_base_quantity numeric(18,4) DEFAULT '0'::numeric NOT NULL,
    conversion_factor numeric(18,6) DEFAULT '1'::numeric NOT NULL
);


--
-- Name: branch_transfers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.branch_transfers (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    transfer_number character varying(60) NOT NULL,
    kind character varying(20) NOT NULL,
    from_branch_id uuid NOT NULL,
    to_branch_id uuid NOT NULL,
    actor_user_id uuid,
    actor_role character varying(20),
    status character varying(20) DEFAULT 'completed'::character varying NOT NULL,
    from_account_id uuid,
    to_account_id uuid,
    amount numeric(18,4),
    currency character varying(10),
    to_currency character varying(10),
    exchange_rate numeric(18,8),
    received_amount numeric(18,4),
    total_cost numeric(18,4),
    reversal_of_id uuid,
    reversed_amount numeric(18,4) DEFAULT '0'::numeric NOT NULL,
    idempotency_key character varying(120),
    notes text,
    created_at timestamp with time zone,
    completed_at timestamp with time zone,
    reversed_at timestamp with time zone
);


--
-- Name: branches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.branches (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    name character varying(200) NOT NULL,
    is_default boolean DEFAULT false,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone,
    is_archived boolean DEFAULT false NOT NULL,
    archived_at timestamp with time zone,
    updated_at timestamp with time zone,
    image character varying(500),
    settings json
);


--
-- Name: business_project_backups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_project_backups (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    payload text NOT NULL,
    checksum text NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: business_project_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_project_settings (
    organization_id uuid NOT NULL,
    settings text DEFAULT '{}'::text NOT NULL,
    updated_at timestamp with time zone
);


--
-- Name: chat_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_messages (
    id uuid NOT NULL,
    link_id uuid NOT NULL,
    merchant_org_id uuid NOT NULL,
    sender_user_id uuid NOT NULL,
    recipient_user_id uuid NOT NULL,
    kind character varying(12) NOT NULL,
    text text,
    media_path character varying(500),
    invoice_id uuid,
    client_id character varying(80),
    delivered_at timestamp with time zone,
    read_at timestamp with time zone,
    created_at timestamp with time zone,
    sender_side character varying(10),
    edited_at timestamp with time zone,
    deleted_at timestamp with time zone,
    file_name character varying(255),
    reply_to_id uuid,
    media text,
    duration_ms integer
);


--
-- Name: chat_presence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_presence (
    user_id uuid NOT NULL,
    last_seen_at timestamp with time zone
);


--
-- Name: cheques; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cheques (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    cheque_number character varying(50) NOT NULL,
    amount numeric(12,2) NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying,
    payee_name character varying(200),
    bank_name character varying(200),
    issue_date timestamp with time zone,
    due_date timestamp with time zone,
    is_deleted boolean DEFAULT false,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: conflict_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conflict_logs (
    id uuid NOT NULL,
    organization_id uuid,
    entity_type character varying(50),
    entity_id uuid,
    client_version integer,
    server_version integer,
    client_data json NOT NULL,
    server_data json,
    resolution character varying(50) NOT NULL,
    resolved_by character varying(50),
    resolved_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL
);


--
-- Name: customer_receivables; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_receivables (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    invoice_id uuid NOT NULL,
    amount numeric(12,2) DEFAULT '0'::numeric NOT NULL,
    paid numeric(12,2) DEFAULT '0'::numeric NOT NULL,
    status character varying(20) DEFAULT 'open'::character varying NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    CONSTRAINT ck_receivable_amount_non_negative CHECK ((amount >= (0)::numeric)),
    CONSTRAINT ck_receivable_paid_non_negative CHECK ((paid >= (0)::numeric)),
    CONSTRAINT ck_receivable_status_valid CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'partial'::character varying, 'paid'::character varying, 'cancelled'::character varying])::text[])))
);


--
-- Name: customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customers (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    name character varying(200) NOT NULL,
    phone character varying(50),
    email character varying(100),
    tax_number character varying(100),
    cr_number character varying(100),
    address text,
    contact_person character varying(200),
    notes text,
    credit_limit numeric(12,2),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    is_deleted boolean,
    deleted_at timestamp with time zone,
    branch_id uuid
);


--
-- Name: debt_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.debt_groups (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    party_kind character varying(10) NOT NULL,
    party_id uuid NOT NULL,
    name character varying(100) NOT NULL,
    kind character varying(10) DEFAULT 'manual'::character varying NOT NULL,
    period character varying(10),
    created_at timestamp with time zone
);


--
-- Name: delivery_note_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.delivery_note_items (
    id uuid NOT NULL,
    delivery_note_id uuid NOT NULL,
    product_id uuid,
    description character varying(500) NOT NULL,
    quantity double precision DEFAULT '1'::double precision NOT NULL,
    unit_price numeric(12,2) DEFAULT '0'::numeric,
    total numeric(12,2) DEFAULT '0'::numeric
);


--
-- Name: delivery_notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.delivery_notes (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    customer_id uuid,
    sales_order_id uuid,
    delivery_number character varying(50) NOT NULL,
    delivery_date date NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    notes text,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: departments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.departments (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    name character varying(200) NOT NULL,
    name_ar character varying(200),
    description text,
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: device_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.device_tokens (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    token character varying(500) NOT NULL,
    platform character varying(30),
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: employee_contracts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.employee_contracts (
    id uuid NOT NULL,
    employee_id uuid NOT NULL,
    contract_type character varying(50),
    start_date date NOT NULL,
    end_date date,
    salary numeric(12,2),
    working_hours double precision,
    notes text,
    status character varying(20),
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: employee_debts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.employee_debts (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    employee_id uuid NOT NULL,
    direction character varying(30) NOT NULL,
    kind character varying(20) DEFAULT 'charge'::character varying NOT NULL,
    amount numeric(18,2) DEFAULT '0'::numeric NOT NULL,
    currency character varying(20) DEFAULT 'SAR'::character varying NOT NULL,
    notes text,
    created_by uuid,
    created_at timestamp with time zone,
    bank_account_id uuid,
    branch_id uuid,
    bank_name character varying(200),
    branch_name character varying(200),
    invoice_no character varying(60),
    receipt_snapshot text
);


--
-- Name: employee_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.employee_documents (
    id uuid NOT NULL,
    employee_id uuid NOT NULL,
    document_type character varying(100),
    document_name character varying(200) NOT NULL,
    file_path character varying(500),
    expiry_date date,
    notes text,
    created_at timestamp with time zone
);


--
-- Name: employee_invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.employee_invitations (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    employee_id uuid NOT NULL,
    invited_user_id uuid NOT NULL,
    invited_by uuid,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    permissions text DEFAULT '{}'::text NOT NULL,
    created_at timestamp with time zone,
    responded_at timestamp with time zone,
    branch_ids text
);


--
-- Name: employee_salary_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.employee_salary_payments (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    employee_id uuid NOT NULL,
    operation_no character varying(60) NOT NULL,
    amount numeric(18,2) DEFAULT '0'::numeric NOT NULL,
    currency character varying(20) DEFAULT 'SAR'::character varying NOT NULL,
    paid_at timestamp with time zone,
    notes text,
    created_by uuid,
    bank_account_id uuid,
    branch_id uuid,
    bank_name character varying(200),
    branch_name character varying(200),
    base_salary numeric(18,2),
    remaining_salary numeric(18,2),
    invoice_no character varying(60),
    receipt_snapshot text
);


--
-- Name: employee_workspace; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.employee_workspace (
    employee_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    linked_user_id uuid,
    photo_url text,
    salary_currency character varying(20) DEFAULT 'SAR'::character varying NOT NULL,
    permissions text DEFAULT '{}'::text NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    last_seen_at timestamp with time zone,
    active_organization_id uuid,
    branch_ids text
);


--
-- Name: employees; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.employees (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    department_id uuid,
    position_id uuid,
    employee_code character varying(50) NOT NULL,
    full_name character varying(200) NOT NULL,
    email character varying(100),
    phone character varying(50),
    hire_date date,
    termination_date date,
    salary numeric(12,2),
    status character varying(20),
    id_number character varying(50),
    id_type character varying(20),
    gender character varying(10),
    date_of_birth date,
    address text,
    emergency_contact character varying(100),
    emergency_phone character varying(50),
    bank_name character varying(200),
    bank_account character varying(100),
    iban character varying(50),
    notes text,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    is_deleted boolean,
    deleted_at timestamp with time zone
);


--
-- Name: entity_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.entity_versions (
    id uuid NOT NULL,
    organization_id uuid,
    entity_type character varying(50),
    entity_id uuid,
    version integer,
    checksum character varying(64) NOT NULL,
    data_hash character varying(64),
    last_modified_at timestamp with time zone NOT NULL,
    last_modified_by uuid NOT NULL,
    is_deleted boolean NOT NULL,
    operation_id character varying(100)
);


--
-- Name: exchange_rate_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.exchange_rate_history (
    id uuid NOT NULL,
    currency_code character varying(20) NOT NULL,
    base_currency character varying(10) NOT NULL,
    rate_type character varying(20),
    buy_rate double precision NOT NULL,
    sell_rate double precision NOT NULL,
    average_rate double precision NOT NULL,
    source character varying(50) NOT NULL,
    provider character varying(100),
    changed_by uuid,
    previous_buy_rate double precision,
    previous_sell_rate double precision,
    previous_average_rate double precision,
    metadata_json text,
    created_at timestamp with time zone,
    effective_at timestamp with time zone
);


--
-- Name: exchange_rate_store; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.exchange_rate_store (
    id uuid NOT NULL,
    currency_code character varying(20) NOT NULL,
    base_currency character varying(10) NOT NULL,
    buy_rate double precision NOT NULL,
    sell_rate double precision NOT NULL,
    average_rate double precision NOT NULL,
    source character varying(50) NOT NULL,
    provider character varying(100),
    fetched_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone
);


--
-- Name: expenses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expenses (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    expense_no character varying(50) NOT NULL,
    category character varying(100) DEFAULT ''::character varying,
    amount numeric(12,2) NOT NULL,
    description text DEFAULT ''::text,
    payment_method character varying(20) DEFAULT 'cash'::character varying,
    expense_date timestamp with time zone,
    is_deleted boolean DEFAULT false,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    currency character varying(10) DEFAULT 'SAR'::character varying NOT NULL,
    bank_account_id uuid,
    branch_id uuid
);


--
-- Name: expiry_notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expiry_notifications (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    product_id uuid NOT NULL,
    notified_on date NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: financial_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.financial_payments (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    payment_no character varying(50) NOT NULL,
    payment_type character varying(20) DEFAULT 'incoming'::character varying,
    payment_method character varying(20) DEFAULT 'cash'::character varying,
    amount numeric(12,2) NOT NULL,
    notes text,
    payment_date timestamp with time zone,
    is_deleted boolean DEFAULT false,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    currency character varying(10) DEFAULT 'SAR'::character varying NOT NULL,
    branch_id uuid
);


--
-- Name: inventory_lot_consumptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inventory_lot_consumptions (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    lot_id uuid NOT NULL,
    invoice_item_id uuid,
    quantity double precision DEFAULT '0'::double precision NOT NULL,
    unit_cost numeric(12,4) DEFAULT '0'::numeric NOT NULL,
    currency character varying(10),
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: inventory_lots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inventory_lots (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    product_id uuid NOT NULL,
    branch_id uuid,
    supplier_id uuid,
    purchase_invoice_id uuid,
    invoice_item_id uuid,
    unit_id uuid,
    received_quantity double precision DEFAULT '0'::double precision NOT NULL,
    remaining_quantity double precision DEFAULT '0'::double precision NOT NULL,
    unit_cost numeric(12,4) DEFAULT '0'::numeric NOT NULL,
    currency character varying(10),
    exchange_rate numeric(18,8) DEFAULT '1'::numeric,
    purchase_date date,
    expiry_date date,
    lot_number character varying(100),
    source character varying(30),
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: inventory_movements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inventory_movements (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    product_id uuid NOT NULL,
    movement_type character varying(50) NOT NULL,
    quantity double precision NOT NULL,
    unit_price numeric(12,2),
    total numeric(12,2),
    reference_type character varying(50),
    reference_id uuid,
    notes text,
    created_by uuid,
    created_at timestamp with time zone,
    currency character varying(10),
    reason character varying(40),
    old_quantity double precision,
    new_quantity double precision,
    difference double precision,
    branch_id uuid
);


--
-- Name: invoice_item_changes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invoice_item_changes (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    invoice_id uuid NOT NULL,
    item_id uuid,
    description character varying(500),
    old_quantity double precision,
    new_quantity double precision,
    old_unit_price numeric(12,2),
    new_unit_price numeric(12,2),
    changed_by uuid,
    changed_at timestamp with time zone
);


--
-- Name: invoice_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invoice_items (
    id uuid NOT NULL,
    invoice_id uuid NOT NULL,
    product_id uuid,
    description character varying(500) NOT NULL,
    quantity double precision NOT NULL,
    unit_price numeric(12,2) NOT NULL,
    discount numeric(12,2),
    tax_rate numeric(5,2),
    total numeric(12,2),
    unit_id uuid,
    unit_name character varying(50),
    base_quantity double precision DEFAULT '0'::double precision,
    is_service boolean DEFAULT false,
    image character varying(500),
    cost_total numeric(12,2),
    profit numeric(12,2),
    original_unit_price numeric(12,2),
    price_currency character varying(10),
    exchange_rate_used numeric(18,8),
    factor numeric(12,4),
    CONSTRAINT ck_invoice_item_qty_positive CHECK ((quantity > (0)::double precision))
);


--
-- Name: invoice_return_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invoice_return_items (
    id uuid NOT NULL,
    return_id uuid NOT NULL,
    invoice_item_id uuid,
    product_id uuid,
    description character varying(500) NOT NULL,
    quantity double precision NOT NULL,
    unit_price numeric(12,2) DEFAULT '0'::numeric NOT NULL,
    total numeric(12,2) DEFAULT '0'::numeric NOT NULL,
    CONSTRAINT ck_return_item_qty_positive CHECK ((quantity > (0)::double precision))
);


--
-- Name: invoice_returns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invoice_returns (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    invoice_id uuid NOT NULL,
    return_number character varying(50) NOT NULL,
    return_date date NOT NULL,
    status character varying(20) DEFAULT 'confirmed'::character varying NOT NULL,
    reason text,
    total numeric(12,2) DEFAULT '0'::numeric NOT NULL,
    created_by uuid,
    created_at timestamp with time zone,
    CONSTRAINT ck_return_status_valid CHECK (((status)::text = ANY ((ARRAY['confirmed'::character varying, 'cancelled'::character varying])::text[])))
);


--
-- Name: invoice_sequences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invoice_sequences (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    prefix character varying(20) NOT NULL,
    last_sequence integer,
    date date NOT NULL
);


--
-- Name: invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invoices (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    invoice_number character varying(50) NOT NULL,
    invoice_type character varying(20) NOT NULL,
    customer_id uuid,
    supplier_id uuid,
    invoice_date date NOT NULL,
    due_date date,
    status character varying(20) NOT NULL,
    subtotal numeric(12,2),
    discount_type character varying(20),
    discount_value numeric(12,2),
    discount_amount numeric(12,2),
    tax_type character varying(20),
    tax_rate numeric(5,2),
    tax_amount numeric(12,2),
    total numeric(12,2),
    paid_amount numeric(12,2),
    balance numeric(12,2),
    notes text,
    terms text,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    is_deleted boolean,
    deleted_at timestamp with time zone,
    confirmed_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    currency character varying(10) DEFAULT 'SAR'::character varying NOT NULL,
    branch_id uuid,
    idempotency_key character varying(100),
    debt_group_id uuid,
    CONSTRAINT ck_invoice_status_valid CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'confirmed'::character varying, 'cancelled'::character varying, 'paid'::character varying, 'partially_paid'::character varying])::text[]))),
    CONSTRAINT ck_invoice_type_valid CHECK (((invoice_type)::text = ANY ((ARRAY['sale'::character varying, 'purchase'::character varying])::text[])))
);


--
-- Name: journal_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.journal_entries (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    entry_number character varying(50) NOT NULL,
    entry_date date NOT NULL,
    description text NOT NULL,
    reference_type character varying(50),
    reference_id uuid,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    posted_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    branch_id uuid
);


--
-- Name: journal_entry_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.journal_entry_lines (
    id uuid NOT NULL,
    journal_entry_id uuid NOT NULL,
    account_id uuid NOT NULL,
    description character varying(500),
    debit numeric(12,2) DEFAULT '0'::numeric,
    credit numeric(12,2) DEFAULT '0'::numeric
);


--
-- Name: leaves; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.leaves (
    id uuid NOT NULL,
    employee_id uuid NOT NULL,
    leave_type character varying(50) NOT NULL,
    start_date date NOT NULL,
    end_date date NOT NULL,
    days double precision NOT NULL,
    reason text,
    status character varying(20),
    approved_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: merchant_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.merchant_links (
    id uuid NOT NULL,
    merchant_org_id uuid NOT NULL,
    party_kind character varying(10) NOT NULL,
    party_id uuid NOT NULL,
    external_user_id uuid,
    phone character varying(50),
    public_code character varying(6),
    status character varying(12) DEFAULT 'pending'::character varying NOT NULL,
    display_name character varying(200),
    invited_by uuid,
    created_at timestamp with time zone,
    responded_at timestamp with time zone,
    linked_via character varying(10)
);


--
-- Name: notification_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_preferences (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    user_id uuid,
    email_alerts boolean,
    invoice_alerts boolean,
    payment_alerts boolean,
    system_updates boolean,
    budget_alerts boolean,
    low_balance_alerts boolean,
    daily_report boolean,
    weekly_report boolean,
    monthly_report boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: org_invoice_designs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.org_invoice_designs (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    template_id character varying(30) NOT NULL,
    payload text NOT NULL,
    updated_at timestamp with time zone,
    branch_id uuid
);


--
-- Name: organizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organizations (
    id uuid NOT NULL,
    name character varying(200) NOT NULL,
    phone character varying(50),
    email character varying(100),
    business_type character varying(50),
    onboarding_completed boolean,
    is_active boolean,
    subscription_plan character varying(100),
    subscription_status character varying(50),
    subscription_start_date timestamp without time zone,
    subscription_end_date timestamp without time zone,
    trial_start_date timestamp without time zone,
    trial_end_date timestamp without time zone,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now(),
    slug character varying(100) NOT NULL,
    has_used_free_plan boolean DEFAULT false NOT NULL,
    section_subscriptions json,
    business_setup_completed boolean DEFAULT false NOT NULL,
    avatar character varying(500)
);


--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    invoice_id uuid NOT NULL,
    amount numeric(12,2) NOT NULL,
    payment_date date NOT NULL,
    payment_method character varying(50),
    reference character varying(200),
    notes text,
    created_by uuid,
    created_at timestamp with time zone,
    bank_account_id uuid,
    payment_currency character varying(10),
    invoice_currency character varying(10),
    original_amount numeric(12,2),
    exchange_rate numeric(18,8),
    equivalent_amount numeric(12,2),
    exchange_rate_source character varying(20),
    exchange_rate_timestamp timestamp with time zone,
    branch_id uuid,
    CONSTRAINT ck_payment_amount_positive CHECK (((amount)::double precision > (0)::double precision)),
    CONSTRAINT ck_payment_method_valid CHECK (((payment_method)::text = ANY ((ARRAY['cash'::character varying, 'bank'::character varying, 'card'::character varying, 'transfer'::character varying, 'cheque'::character varying])::text[])))
);


--
-- Name: payroll_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payroll_items (
    id uuid NOT NULL,
    payroll_id uuid NOT NULL,
    employee_id uuid,
    basic_salary numeric(12,2),
    allowances numeric(12,2),
    deductions numeric(12,2),
    bonus numeric(12,2),
    overtime numeric(12,2),
    net_salary numeric(12,2),
    total_days double precision,
    working_days double precision,
    absence_days double precision
);


--
-- Name: payrolls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payrolls (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    month integer NOT NULL,
    year integer NOT NULL,
    status character varying(20),
    total_salary numeric(12,2),
    total_deductions numeric(12,2),
    total_bonuses numeric(12,2),
    net_total numeric(12,2),
    notes text,
    processed_by uuid,
    processed_at timestamp with time zone,
    created_at timestamp with time zone
);


--
-- Name: pending_registrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pending_registrations (
    id uuid NOT NULL,
    email character varying(100) NOT NULL,
    full_name character varying(200) NOT NULL,
    phone character varying(50),
    password_hash character varying(255) NOT NULL,
    organization_name character varying(200),
    preferred_usage_mode character varying(20),
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone NOT NULL
);


--
-- Name: personal_bank_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.personal_bank_accounts (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    bank_name character varying(200) NOT NULL,
    currency character varying(10),
    balance numeric(12,2),
    notes text,
    sort_order integer,
    is_active boolean,
    is_deleted boolean,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: personal_budget_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.personal_budget_categories (
    id uuid NOT NULL,
    budget_id uuid NOT NULL,
    name character varying(100) NOT NULL,
    type character varying(20) NOT NULL,
    allocated_amount numeric(12,2),
    spent_amount numeric(12,2),
    currency character varying(10),
    goal_id uuid,
    debt_id uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: personal_budgets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.personal_budgets (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    name character varying(200) NOT NULL,
    period_type character varying(30),
    start_date timestamp with time zone,
    end_date timestamp with time zone,
    custom_days integer,
    total_amount numeric(12,2) NOT NULL,
    currency character varying(10),
    bank_account_ids json,
    budget_types json,
    is_deleted boolean,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    category character varying(100),
    amount numeric(12,2),
    spent numeric(12,2),
    month integer,
    year integer
);


--
-- Name: personal_debt_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.personal_debt_payments (
    id uuid NOT NULL,
    debt_id uuid NOT NULL,
    user_id uuid NOT NULL,
    amount numeric(12,2) NOT NULL,
    currency character varying(10),
    payment_date timestamp with time zone,
    notes text,
    budget_id uuid,
    is_deleted boolean,
    created_at timestamp with time zone
);


--
-- Name: personal_debts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.personal_debts (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    debt_type character varying(20) NOT NULL,
    person_name character varying(200) NOT NULL,
    amount numeric(12,2) NOT NULL,
    currency character varying(10),
    description text,
    due_date date,
    is_paid boolean,
    paid_date date,
    reminder boolean,
    budget_id uuid,
    is_deleted boolean,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: personal_recurring_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.personal_recurring_transactions (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    name character varying(200),
    tx_type character varying(20) NOT NULL,
    amount numeric(12,2) NOT NULL,
    currency character varying(10),
    category character varying(100) NOT NULL,
    description text,
    frequency character varying(20) NOT NULL,
    interval_value integer,
    next_run_date date,
    account_type character varying(20),
    bank_account_id uuid,
    execution_type character varying(20),
    reminder_time character varying(10),
    approximate_start_day integer,
    approximate_end_day integer,
    last_executed_at timestamp with time zone,
    is_active boolean,
    is_deleted boolean,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: personal_savings_goals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.personal_savings_goals (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    name character varying(200) NOT NULL,
    target_amount numeric(12,2) NOT NULL,
    current_amount numeric(12,2),
    currency character varying(10),
    deadline date,
    icon character varying(50),
    notes text,
    budget_id uuid,
    is_completed boolean,
    is_deleted boolean,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: personal_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.personal_transactions (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    tx_type character varying(20) NOT NULL,
    amount numeric(12,2) NOT NULL,
    currency character varying(10),
    category character varying(100) NOT NULL,
    description text,
    bank_account_id uuid,
    budget_id uuid,
    budget_category_id uuid,
    goal_id uuid,
    debt_id uuid,
    goal_amount numeric(12,2),
    debt_amount numeric(12,2),
    payment_method character varying(20),
    date timestamp with time zone,
    exchange_rate numeric(20,8),
    exchange_rate_currency character varying(10),
    fx_source character varying(30),
    client_operation_id character varying(64),
    is_deleted boolean,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plans (
    id uuid NOT NULL,
    name character varying(100) NOT NULL,
    name_en character varying(100),
    description text,
    price_monthly double precision,
    price_yearly double precision,
    currency character varying(10),
    features text,
    color character varying(20),
    icon character varying(50),
    package_type character varying(20),
    duration_days integer,
    is_active boolean,
    max_users integer,
    max_storage_gb integer,
    stripe_product_id character varying(100),
    stripe_price_id_monthly character varying(100),
    stripe_price_id_yearly character varying(100),
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: platform_bank_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_bank_accounts (
    id uuid NOT NULL,
    bank_name character varying(200) NOT NULL,
    account_holder_name character varying(200),
    account_number character varying(50),
    iban character varying(50),
    country character varying(10),
    currency character varying(10),
    opening_balance numeric(14,2),
    currencies text,
    notes text,
    is_active boolean,
    is_system boolean,
    sort_order integer,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: platform_notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_notifications (
    id uuid NOT NULL,
    title character varying(300) NOT NULL,
    message text,
    target character varying(30),
    type character varying(30),
    read_count integer,
    sent_at timestamp with time zone,
    created_at timestamp with time zone
);


--
-- Name: positions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.positions (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    department_id uuid,
    title character varying(200) NOT NULL,
    title_ar character varying(200),
    description text,
    is_active boolean,
    created_at timestamp with time zone
);


--
-- Name: product_barcodes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_barcodes (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    product_id uuid NOT NULL,
    unit_id uuid,
    barcode character varying(100) NOT NULL
);


--
-- Name: product_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_categories (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    name character varying(200) NOT NULL,
    name_ar character varying(200),
    description text,
    is_active boolean,
    created_at timestamp with time zone,
    is_deleted boolean DEFAULT false,
    deleted_at timestamp with time zone,
    image character varying(500)
);


--
-- Name: product_prices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_prices (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    product_id uuid NOT NULL,
    currency character varying(10) NOT NULL,
    price numeric(12,2) DEFAULT '0'::numeric NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    buy_price numeric(12,2)
);


--
-- Name: product_units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_units (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    product_id uuid NOT NULL,
    name character varying(50) NOT NULL,
    factor numeric(12,4) DEFAULT '1'::numeric NOT NULL,
    barcode character varying(100),
    sale_price numeric(12,2),
    purchase_price numeric(12,2),
    is_base boolean DEFAULT false,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    "group" character varying(20),
    CONSTRAINT ck_unit_factor_positive CHECK ((factor > (0)::numeric))
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    category_id uuid,
    name character varying(200) NOT NULL,
    name_ar character varying(200),
    sku character varying(100),
    barcode character varying(100),
    description text,
    unit character varying(50),
    price numeric(12,2) NOT NULL,
    cost_price numeric(12,2),
    stock numeric(18,4),
    min_stock numeric(18,4),
    is_service boolean,
    is_active boolean,
    image character varying(500),
    notes text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    is_deleted boolean,
    deleted_at timestamp with time zone,
    cost_currency character varying(10),
    expiry_date date,
    branch_id uuid,
    CONSTRAINT ck_product_price_non_negative CHECK (((price)::double precision >= (0)::double precision))
);


--
-- Name: purchase_order_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.purchase_order_items (
    id uuid NOT NULL,
    purchase_order_id uuid NOT NULL,
    product_id uuid,
    description character varying(500) NOT NULL,
    quantity double precision DEFAULT '1'::double precision NOT NULL,
    unit_price numeric(12,2) DEFAULT '0'::numeric NOT NULL,
    discount numeric(12,2) DEFAULT '0'::numeric,
    total numeric(12,2) DEFAULT '0'::numeric
);


--
-- Name: purchase_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.purchase_orders (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    supplier_id uuid,
    order_number character varying(50) NOT NULL,
    order_date date NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    subtotal numeric(12,2) DEFAULT '0'::numeric,
    discount_type character varying(20),
    discount_value numeric(12,2) DEFAULT '0'::numeric,
    discount_amount numeric(12,2) DEFAULT '0'::numeric,
    tax_type character varying(20),
    tax_rate numeric(5,2) DEFAULT '0'::numeric,
    tax_amount numeric(12,2) DEFAULT '0'::numeric,
    total numeric(12,2) DEFAULT '0'::numeric,
    paid_amount numeric(12,2) DEFAULT '0'::numeric,
    balance numeric(12,2) DEFAULT '0'::numeric,
    notes text,
    terms text,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    is_deleted boolean DEFAULT false,
    deleted_at timestamp with time zone,
    confirmed_at timestamp with time zone,
    received_at timestamp with time zone,
    cancelled_at timestamp with time zone
);


--
-- Name: purchase_receipt_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.purchase_receipt_items (
    id uuid NOT NULL,
    purchase_receipt_id uuid NOT NULL,
    product_id uuid,
    description character varying(500) NOT NULL,
    quantity double precision DEFAULT '1'::double precision NOT NULL,
    unit_price numeric(12,2) DEFAULT '0'::numeric,
    total numeric(12,2) DEFAULT '0'::numeric
);


--
-- Name: purchase_receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.purchase_receipts (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    supplier_id uuid,
    purchase_order_id uuid,
    receipt_number character varying(50) NOT NULL,
    receipt_date date NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    notes text,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: purchase_return_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.purchase_return_items (
    id uuid NOT NULL,
    purchase_return_id uuid NOT NULL,
    product_id uuid,
    description character varying(500) NOT NULL,
    quantity double precision DEFAULT '1'::double precision NOT NULL,
    unit_price numeric(12,2) DEFAULT '0'::numeric,
    total numeric(12,2) DEFAULT '0'::numeric,
    invoice_item_id uuid
);


--
-- Name: purchase_returns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.purchase_returns (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    supplier_id uuid,
    purchase_order_id uuid,
    return_number character varying(50) NOT NULL,
    return_date date NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    reason text,
    total numeric(12,2) DEFAULT '0'::numeric,
    notes text,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    invoice_id uuid
);


--
-- Name: quote_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quote_items (
    id uuid NOT NULL,
    quote_id uuid NOT NULL,
    product_id uuid,
    description character varying(500) NOT NULL,
    quantity double precision DEFAULT '1'::double precision NOT NULL,
    unit_price numeric(12,2) DEFAULT '0'::numeric NOT NULL,
    discount numeric(12,2) DEFAULT '0'::numeric,
    total numeric(12,2) DEFAULT '0'::numeric
);


--
-- Name: reconciliations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reconciliations (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    branch_id uuid,
    ref_code character varying(40),
    rtype character varying(20) NOT NULL,
    scope character varying(20) DEFAULT 'accounts'::character varying NOT NULL,
    scope_json text DEFAULT '{}'::text NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    period_start timestamp with time zone,
    period_end timestamp with time zone,
    measured_at timestamp with time zone,
    notes text,
    lines_json text DEFAULT '[]'::text NOT NULL,
    settlements_json text,
    result_json text,
    created_by uuid,
    approved_by uuid,
    created_at timestamp with time zone,
    approved_at timestamp with time zone,
    idempotency_key character varying(80),
    updated_at timestamp with time zone
);


--
-- Name: reminders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reminders (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    user_id uuid,
    title character varying(300) NOT NULL,
    message text,
    remind_at timestamp with time zone NOT NULL,
    repeat character varying(20),
    is_active boolean,
    last_triggered_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: role_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_permissions (
    id uuid NOT NULL,
    role_id uuid NOT NULL,
    resource character varying(100) NOT NULL,
    can_create boolean DEFAULT false,
    can_read boolean DEFAULT false,
    can_update boolean DEFAULT false,
    can_delete boolean DEFAULT false
);


--
-- Name: roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    name character varying(100) NOT NULL,
    name_ar character varying(100),
    is_system boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: sales_order_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sales_order_items (
    id uuid NOT NULL,
    sales_order_id uuid NOT NULL,
    product_id uuid,
    description character varying(500) NOT NULL,
    quantity double precision DEFAULT '1'::double precision NOT NULL,
    unit_price numeric(12,2) DEFAULT '0'::numeric NOT NULL,
    discount numeric(12,2) DEFAULT '0'::numeric,
    tax_rate numeric(5,2) DEFAULT '0'::numeric,
    total numeric(12,2) DEFAULT '0'::numeric
);


--
-- Name: sales_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sales_orders (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    customer_id uuid,
    order_number character varying(50) NOT NULL,
    order_date date NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    subtotal numeric(12,2) DEFAULT '0'::numeric,
    discount_type character varying(20),
    discount_value numeric(12,2) DEFAULT '0'::numeric,
    discount_amount numeric(12,2) DEFAULT '0'::numeric,
    tax_type character varying(20),
    tax_rate numeric(5,2) DEFAULT '0'::numeric,
    tax_amount numeric(12,2) DEFAULT '0'::numeric,
    total numeric(12,2) DEFAULT '0'::numeric,
    paid_amount numeric(12,2) DEFAULT '0'::numeric,
    balance numeric(12,2) DEFAULT '0'::numeric,
    notes text,
    terms text,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    is_deleted boolean DEFAULT false,
    deleted_at timestamp with time zone,
    confirmed_at timestamp with time zone,
    delivered_at timestamp with time zone,
    cancelled_at timestamp with time zone
);


--
-- Name: sales_quotes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sales_quotes (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    customer_id uuid,
    quote_number character varying(50) NOT NULL,
    quote_date date NOT NULL,
    expiry_date date,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    subtotal numeric(12,2) DEFAULT '0'::numeric,
    discount_type character varying(20),
    discount_value numeric(12,2) DEFAULT '0'::numeric,
    discount_amount numeric(12,2) DEFAULT '0'::numeric,
    tax_type character varying(20),
    tax_rate numeric(5,2) DEFAULT '0'::numeric,
    tax_amount numeric(12,2) DEFAULT '0'::numeric,
    total numeric(12,2) DEFAULT '0'::numeric,
    notes text,
    terms text,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: sales_return_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sales_return_items (
    id uuid NOT NULL,
    sales_return_id uuid NOT NULL,
    product_id uuid,
    description character varying(500) NOT NULL,
    quantity double precision DEFAULT '1'::double precision NOT NULL,
    unit_price numeric(12,2) DEFAULT '0'::numeric,
    total numeric(12,2) DEFAULT '0'::numeric
);


--
-- Name: sales_returns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sales_returns (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    customer_id uuid,
    sales_order_id uuid,
    return_number character varying(50) NOT NULL,
    return_date date NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    reason text,
    total numeric(12,2) DEFAULT '0'::numeric,
    notes text,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: settlement_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.settlement_requests (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    party_kind character varying(10) NOT NULL,
    party_id uuid NOT NULL,
    link_id uuid,
    external_user_id uuid,
    amount numeric(18,4) NOT NULL,
    currency character varying(10) NOT NULL,
    method character varying(20),
    reference character varying(100),
    receipt_url character varying(500),
    note text,
    status character varying(12) DEFAULT 'pending'::character varying NOT NULL,
    reject_reason text,
    idempotency_key character varying(80),
    payment_id uuid,
    created_at timestamp with time zone,
    decided_at timestamp with time zone
);


--
-- Name: shared_audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shared_audit_log (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    entity_type character varying(30) NOT NULL,
    entity_id character varying(60),
    action character varying(30) NOT NULL,
    before_json text,
    after_json text,
    reason text,
    actor_user_id uuid,
    created_at timestamp with time zone
);


--
-- Name: stripe_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stripe_payments (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    plan_id uuid,
    provider character varying(20),
    stripe_checkout_session_id character varying(255),
    stripe_payment_intent_id character varying(255),
    stripe_event_id character varying(255),
    amount double precision,
    amount_minor integer,
    currency character varying(10),
    base_currency character varying(10),
    base_amount double precision,
    exchange_rate double precision,
    fx_source character varying(20),
    mode character varying(10),
    idempotency_key character varying(200),
    status character varying(20),
    plan_name character varying(50),
    period character varying(20),
    metadata text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: stripe_webhook_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stripe_webhook_events (
    event_id character varying(255) NOT NULL,
    event_type character varying(100) NOT NULL,
    status character varying(20),
    processed_at timestamp with time zone
);


--
-- Name: subscription_invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_invoices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    invoice_number character varying(50) NOT NULL,
    organization_id uuid NOT NULL,
    user_id uuid,
    request_id uuid,
    plan_name character varying(200) NOT NULL,
    plan_description text,
    period character varying(20) DEFAULT 'yearly'::character varying NOT NULL,
    amount numeric(14,2) DEFAULT '0'::numeric NOT NULL,
    currency character varying(10) DEFAULT 'SAR'::character varying NOT NULL,
    status character varying(20) DEFAULT 'paid'::character varying NOT NULL,
    payment_method character varying(50) DEFAULT 'bank_transfer'::character varying,
    subscription_start_date timestamp with time zone,
    subscription_end_date timestamp with time zone,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    bank_name character varying(200),
    card_brand character varying(50),
    provider_payment_id character varying(200)
);


--
-- Name: subscription_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_requests (
    id uuid NOT NULL,
    user_id uuid,
    organization_id uuid,
    plan_id character varying(50) NOT NULL,
    plan_name character varying(200),
    status character varying(20),
    message text,
    proof_image character varying(500),
    proof_images text,
    period character varying(20),
    currency character varying(10),
    rejection_reason text,
    created_at timestamp with time zone,
    reviewed_at timestamp with time zone,
    reviewed_by uuid
);


--
-- Name: subscription_revenues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_revenues (
    id uuid NOT NULL,
    request_id uuid,
    organization_id uuid,
    user_id uuid,
    bank_account_id uuid,
    plan_name character varying(200),
    period character varying(20),
    amount numeric(14,2) NOT NULL,
    currency character varying(10),
    note text,
    provider_payment_id character varying(200),
    created_at timestamp with time zone
);


--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscriptions (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    plan_id uuid,
    stripe_customer_id character varying(255),
    stripe_subscription_id character varying(255),
    plan_name character varying(50),
    status character varying(20),
    current_period_start timestamp with time zone,
    current_period_end timestamp with time zone,
    cancel_at_period_end boolean,
    renewal_retry_count integer,
    renewal_next_retry_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: suggestion_replies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.suggestion_replies (
    id uuid NOT NULL,
    suggestion_id uuid NOT NULL,
    user_id uuid NOT NULL,
    admin_id uuid,
    body text NOT NULL,
    is_deleted boolean,
    is_edited boolean,
    images json,
    videos json,
    audios json,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: suggestions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.suggestions (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    organization_id uuid,
    title character varying(200) DEFAULT ''::character varying,
    body text NOT NULL,
    images json DEFAULT '[]'::json,
    status character varying(20) DEFAULT 'pending'::character varying,
    admin_note text,
    is_deleted boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    videos json,
    audios json,
    admin_read_at timestamp with time zone
);


--
-- Name: supplier_bills; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supplier_bills (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    supplier_id uuid,
    purchase_order_id uuid,
    bill_number character varying(50) NOT NULL,
    bill_date date NOT NULL,
    due_date date,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    subtotal numeric(12,2) DEFAULT '0'::numeric,
    discount_type character varying(20),
    discount_value numeric(12,2) DEFAULT '0'::numeric,
    discount_amount numeric(12,2) DEFAULT '0'::numeric,
    tax_type character varying(20),
    tax_rate numeric(5,2) DEFAULT '0'::numeric,
    tax_amount numeric(12,2) DEFAULT '0'::numeric,
    total numeric(12,2) DEFAULT '0'::numeric,
    paid_amount numeric(12,2) DEFAULT '0'::numeric,
    balance numeric(12,2) DEFAULT '0'::numeric,
    notes text,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: supplier_payables; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supplier_payables (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    supplier_id uuid NOT NULL,
    invoice_id uuid NOT NULL,
    amount numeric(12,2) DEFAULT '0'::numeric NOT NULL,
    paid numeric(12,2) DEFAULT '0'::numeric NOT NULL,
    status character varying(20) DEFAULT 'open'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT ck_payable_amount_non_negative CHECK ((amount >= (0)::numeric)),
    CONSTRAINT ck_payable_paid_non_negative CHECK ((paid >= (0)::numeric)),
    CONSTRAINT ck_payable_status_valid CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'partial'::character varying, 'paid'::character varying, 'cancelled'::character varying])::text[])))
);


--
-- Name: suppliers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.suppliers (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    name character varying(200) NOT NULL,
    phone character varying(50),
    email character varying(100),
    tax_number character varying(100),
    cr_number character varying(100),
    address text,
    contact_person character varying(200),
    notes text,
    is_active boolean,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    is_deleted boolean,
    deleted_at timestamp with time zone,
    branch_id uuid
);


--
-- Name: sync_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sync_batches (
    id uuid NOT NULL,
    organization_id uuid,
    batch_id character varying(100),
    direction character varying(10),
    status character varying(20) NOT NULL,
    entity_count integer NOT NULL,
    success_count integer NOT NULL,
    error_count integer NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    created_at timestamp with time zone
);


--
-- Name: sync_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sync_logs (
    id uuid NOT NULL,
    organization_id uuid,
    entity_type character varying(50),
    entity_id uuid NOT NULL,
    action character varying(20),
    status character varying(20),
    details text,
    created_at timestamp with time zone NOT NULL
);


--
-- Name: trash_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trash_items (
    id uuid NOT NULL,
    item_type character varying(50) NOT NULL,
    item_id character varying(100) NOT NULL,
    item_name character varying(300),
    payload text,
    status character varying(20),
    deleted_by uuid,
    created_at timestamp with time zone,
    restored_at timestamp with time zone
);


--
-- Name: user_backup_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_backup_keys (
    user_id uuid NOT NULL,
    key_b64 text NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: user_backups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_backups (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    schema_version character varying(20) DEFAULT '4.0.0'::character varying NOT NULL,
    filename character varying(255) NOT NULL,
    storage_key character varying(500) NOT NULL,
    size_bytes bigint DEFAULT '0'::bigint NOT NULL,
    record_count integer DEFAULT 0 NOT NULL,
    checksum character varying(128) DEFAULT ''::character varying NOT NULL,
    hmac character varying(256) DEFAULT ''::character varying NOT NULL,
    status character varying(30) DEFAULT 'complete'::character varying NOT NULL,
    backup_meta json DEFAULT '{}'::json,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: user_code_seq; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_code_seq (
    id integer NOT NULL,
    next_val bigint DEFAULT '0'::bigint NOT NULL
);


--
-- Name: user_code_seq_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_code_seq_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_code_seq_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_code_seq_id_seq OWNED BY public.user_code_seq.id;


--
-- Name: user_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_sessions (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    refresh_token character varying(500) NOT NULL,
    device_name character varying(200),
    ip_address character varying(50),
    user_agent text,
    is_active boolean DEFAULT true,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    is_primary boolean DEFAULT false NOT NULL,
    custom_name character varying(200),
    device_model character varying(200),
    os_version character varying(50),
    country character varying(100),
    region character varying(100),
    city character varying(100),
    last_activity timestamp with time zone,
    fingerprint character varying(100)
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid NOT NULL,
    email character varying(100),
    password_hash character varying(255),
    full_name character varying(200),
    phone character varying(50),
    role character varying(20) NOT NULL,
    is_active boolean,
    status character varying(20),
    mfa_enabled boolean,
    is_platform_admin boolean,
    last_login timestamp without time zone,
    preferred_usage_mode character varying(20),
    organization_id uuid NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now(),
    avatar character varying(500),
    preferred_language character varying(10) DEFAULT 'ar'::character varying,
    preferred_currency character varying(10) DEFAULT 'SAR'::character varying,
    timezone character varying(50) DEFAULT 'Asia/Riyadh'::character varying,
    email_verified boolean DEFAULT false,
    last_login_at timestamp with time zone,
    firebase_uid character varying(128),
    auth_provider character varying(50) DEFAULT 'email'::character varying,
    photo_url character varying(500),
    phone_country character varying(10),
    phone_calling_code character varying(10),
    phone_type character varying(30),
    phone_carrier character varying(100),
    phone_added_at timestamp with time zone,
    phone_updated_at timestamp with time zone,
    tokens_valid_after timestamp with time zone,
    public_code character varying(6),
    phone_lookup_digits character varying(32),
    phone_national_digits character varying(32)
);


--
-- Name: warehouse_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.warehouse_settings (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    expiry_enabled boolean DEFAULT false NOT NULL,
    expiry_warn_days integer DEFAULT 60 NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: user_code_seq id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_code_seq ALTER COLUMN id SET DEFAULT nextval('public.user_code_seq_id_seq'::regclass);


--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);


--
-- Name: admin_exchange_rates admin_exchange_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_exchange_rates
    ADD CONSTRAINT admin_exchange_rates_pkey PRIMARY KEY (id);


--
-- Name: admin_operations admin_operations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_operations
    ADD CONSTRAINT admin_operations_pkey PRIMARY KEY (id);


--
-- Name: admin_permissions admin_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_permissions
    ADD CONSTRAINT admin_permissions_pkey PRIMARY KEY (id);


--
-- Name: agent_analytics_events agent_analytics_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_analytics_events
    ADD CONSTRAINT agent_analytics_events_pkey PRIMARY KEY (id);


--
-- Name: alembic_version alembic_version_pkc; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alembic_version
    ADD CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num);


--
-- Name: app_config app_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_config
    ADD CONSTRAINT app_config_pkey PRIMARY KEY (key);


--
-- Name: app_notifications app_notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_notifications
    ADD CONSTRAINT app_notifications_pkey PRIMARY KEY (id);


--
-- Name: attendances attendances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendances
    ADD CONSTRAINT attendances_pkey PRIMARY KEY (id);


--
-- Name: bank_accounts bank_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_accounts
    ADD CONSTRAINT bank_accounts_pkey PRIMARY KEY (id);


--
-- Name: bank_transactions bank_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_transactions
    ADD CONSTRAINT bank_transactions_pkey PRIMARY KEY (id);


--
-- Name: branch_invitations branch_invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_invitations
    ADD CONSTRAINT branch_invitations_pkey PRIMARY KEY (id);


--
-- Name: branch_members branch_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_members
    ADD CONSTRAINT branch_members_pkey PRIMARY KEY (id);


--
-- Name: branch_stock branch_stock_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_stock
    ADD CONSTRAINT branch_stock_pkey PRIMARY KEY (id);


--
-- Name: branch_transfer_items branch_transfer_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_transfer_items
    ADD CONSTRAINT branch_transfer_items_pkey PRIMARY KEY (id);


--
-- Name: branch_transfers branch_transfers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_transfers
    ADD CONSTRAINT branch_transfers_pkey PRIMARY KEY (id);


--
-- Name: branches branches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branches
    ADD CONSTRAINT branches_pkey PRIMARY KEY (id);


--
-- Name: business_project_backups business_project_backups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_project_backups
    ADD CONSTRAINT business_project_backups_pkey PRIMARY KEY (id);


--
-- Name: business_project_settings business_project_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_project_settings
    ADD CONSTRAINT business_project_settings_pkey PRIMARY KEY (organization_id);


--
-- Name: chat_messages chat_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT chat_messages_pkey PRIMARY KEY (id);


--
-- Name: chat_presence chat_presence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_presence
    ADD CONSTRAINT chat_presence_pkey PRIMARY KEY (user_id);


--
-- Name: cheques cheques_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cheques
    ADD CONSTRAINT cheques_pkey PRIMARY KEY (id);


--
-- Name: conflict_logs conflict_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conflict_logs
    ADD CONSTRAINT conflict_logs_pkey PRIMARY KEY (id);


--
-- Name: customer_receivables customer_receivables_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_receivables
    ADD CONSTRAINT customer_receivables_pkey PRIMARY KEY (id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: debt_groups debt_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.debt_groups
    ADD CONSTRAINT debt_groups_pkey PRIMARY KEY (id);


--
-- Name: delivery_note_items delivery_note_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_note_items
    ADD CONSTRAINT delivery_note_items_pkey PRIMARY KEY (id);


--
-- Name: delivery_notes delivery_notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_notes
    ADD CONSTRAINT delivery_notes_pkey PRIMARY KEY (id);


--
-- Name: departments departments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.departments
    ADD CONSTRAINT departments_pkey PRIMARY KEY (id);


--
-- Name: device_tokens device_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_tokens
    ADD CONSTRAINT device_tokens_pkey PRIMARY KEY (id);


--
-- Name: employee_contracts employee_contracts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_contracts
    ADD CONSTRAINT employee_contracts_pkey PRIMARY KEY (id);


--
-- Name: employee_debts employee_debts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_debts
    ADD CONSTRAINT employee_debts_pkey PRIMARY KEY (id);


--
-- Name: employee_documents employee_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_documents
    ADD CONSTRAINT employee_documents_pkey PRIMARY KEY (id);


--
-- Name: employee_invitations employee_invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_invitations
    ADD CONSTRAINT employee_invitations_pkey PRIMARY KEY (id);


--
-- Name: employee_salary_payments employee_salary_payments_operation_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_salary_payments
    ADD CONSTRAINT employee_salary_payments_operation_no_key UNIQUE (operation_no);


--
-- Name: employee_salary_payments employee_salary_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_salary_payments
    ADD CONSTRAINT employee_salary_payments_pkey PRIMARY KEY (id);


--
-- Name: employee_workspace employee_workspace_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_workspace
    ADD CONSTRAINT employee_workspace_pkey PRIMARY KEY (employee_id);


--
-- Name: employees employees_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employees
    ADD CONSTRAINT employees_pkey PRIMARY KEY (id);


--
-- Name: entity_versions entity_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entity_versions
    ADD CONSTRAINT entity_versions_pkey PRIMARY KEY (id);


--
-- Name: exchange_rate_history exchange_rate_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_rate_history
    ADD CONSTRAINT exchange_rate_history_pkey PRIMARY KEY (id);


--
-- Name: exchange_rate_store exchange_rate_store_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_rate_store
    ADD CONSTRAINT exchange_rate_store_pkey PRIMARY KEY (id);


--
-- Name: expenses expenses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_pkey PRIMARY KEY (id);


--
-- Name: expiry_notifications expiry_notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expiry_notifications
    ADD CONSTRAINT expiry_notifications_pkey PRIMARY KEY (id);


--
-- Name: financial_payments financial_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_payments
    ADD CONSTRAINT financial_payments_pkey PRIMARY KEY (id);


--
-- Name: inventory_lot_consumptions inventory_lot_consumptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_lot_consumptions
    ADD CONSTRAINT inventory_lot_consumptions_pkey PRIMARY KEY (id);


--
-- Name: inventory_lots inventory_lots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_lots
    ADD CONSTRAINT inventory_lots_pkey PRIMARY KEY (id);


--
-- Name: inventory_movements inventory_movements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_movements
    ADD CONSTRAINT inventory_movements_pkey PRIMARY KEY (id);


--
-- Name: invoice_item_changes invoice_item_changes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_item_changes
    ADD CONSTRAINT invoice_item_changes_pkey PRIMARY KEY (id);


--
-- Name: invoice_items invoice_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_items
    ADD CONSTRAINT invoice_items_pkey PRIMARY KEY (id);


--
-- Name: invoice_return_items invoice_return_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_return_items
    ADD CONSTRAINT invoice_return_items_pkey PRIMARY KEY (id);


--
-- Name: invoice_returns invoice_returns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_returns
    ADD CONSTRAINT invoice_returns_pkey PRIMARY KEY (id);


--
-- Name: invoice_sequences invoice_sequences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_sequences
    ADD CONSTRAINT invoice_sequences_pkey PRIMARY KEY (id);


--
-- Name: invoices invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_pkey PRIMARY KEY (id);


--
-- Name: journal_entries journal_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_pkey PRIMARY KEY (id);


--
-- Name: journal_entry_lines journal_entry_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entry_lines
    ADD CONSTRAINT journal_entry_lines_pkey PRIMARY KEY (id);


--
-- Name: leaves leaves_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leaves
    ADD CONSTRAINT leaves_pkey PRIMARY KEY (id);


--
-- Name: merchant_links merchant_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.merchant_links
    ADD CONSTRAINT merchant_links_pkey PRIMARY KEY (id);


--
-- Name: notification_preferences notification_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_preferences
    ADD CONSTRAINT notification_preferences_pkey PRIMARY KEY (id);


--
-- Name: org_invoice_designs org_invoice_designs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.org_invoice_designs
    ADD CONSTRAINT org_invoice_designs_pkey PRIMARY KEY (id);


--
-- Name: organizations organizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_pkey PRIMARY KEY (id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: payroll_items payroll_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payroll_items
    ADD CONSTRAINT payroll_items_pkey PRIMARY KEY (id);


--
-- Name: payrolls payrolls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payrolls
    ADD CONSTRAINT payrolls_pkey PRIMARY KEY (id);


--
-- Name: pending_registrations pending_registrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_registrations
    ADD CONSTRAINT pending_registrations_pkey PRIMARY KEY (id);


--
-- Name: personal_bank_accounts personal_bank_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_bank_accounts
    ADD CONSTRAINT personal_bank_accounts_pkey PRIMARY KEY (id);


--
-- Name: personal_budget_categories personal_budget_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_budget_categories
    ADD CONSTRAINT personal_budget_categories_pkey PRIMARY KEY (id);


--
-- Name: personal_budgets personal_budgets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_budgets
    ADD CONSTRAINT personal_budgets_pkey PRIMARY KEY (id);


--
-- Name: personal_debt_payments personal_debt_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_debt_payments
    ADD CONSTRAINT personal_debt_payments_pkey PRIMARY KEY (id);


--
-- Name: personal_debts personal_debts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_debts
    ADD CONSTRAINT personal_debts_pkey PRIMARY KEY (id);


--
-- Name: personal_recurring_transactions personal_recurring_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_recurring_transactions
    ADD CONSTRAINT personal_recurring_transactions_pkey PRIMARY KEY (id);


--
-- Name: personal_savings_goals personal_savings_goals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_savings_goals
    ADD CONSTRAINT personal_savings_goals_pkey PRIMARY KEY (id);


--
-- Name: personal_transactions personal_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_transactions
    ADD CONSTRAINT personal_transactions_pkey PRIMARY KEY (id);


--
-- Name: plans plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plans
    ADD CONSTRAINT plans_pkey PRIMARY KEY (id);


--
-- Name: platform_bank_accounts platform_bank_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_bank_accounts
    ADD CONSTRAINT platform_bank_accounts_pkey PRIMARY KEY (id);


--
-- Name: platform_notifications platform_notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_notifications
    ADD CONSTRAINT platform_notifications_pkey PRIMARY KEY (id);


--
-- Name: positions positions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.positions
    ADD CONSTRAINT positions_pkey PRIMARY KEY (id);


--
-- Name: product_barcodes product_barcodes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_barcodes
    ADD CONSTRAINT product_barcodes_pkey PRIMARY KEY (id);


--
-- Name: product_categories product_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_categories
    ADD CONSTRAINT product_categories_pkey PRIMARY KEY (id);


--
-- Name: product_prices product_prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_prices
    ADD CONSTRAINT product_prices_pkey PRIMARY KEY (id);


--
-- Name: product_units product_units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_units
    ADD CONSTRAINT product_units_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: purchase_order_items purchase_order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_items
    ADD CONSTRAINT purchase_order_items_pkey PRIMARY KEY (id);


--
-- Name: purchase_orders purchase_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_pkey PRIMARY KEY (id);


--
-- Name: purchase_receipt_items purchase_receipt_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_receipt_items
    ADD CONSTRAINT purchase_receipt_items_pkey PRIMARY KEY (id);


--
-- Name: purchase_receipts purchase_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_receipts
    ADD CONSTRAINT purchase_receipts_pkey PRIMARY KEY (id);


--
-- Name: purchase_return_items purchase_return_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_return_items
    ADD CONSTRAINT purchase_return_items_pkey PRIMARY KEY (id);


--
-- Name: purchase_returns purchase_returns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_returns
    ADD CONSTRAINT purchase_returns_pkey PRIMARY KEY (id);


--
-- Name: quote_items quote_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quote_items
    ADD CONSTRAINT quote_items_pkey PRIMARY KEY (id);


--
-- Name: reconciliations reconciliations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliations
    ADD CONSTRAINT reconciliations_pkey PRIMARY KEY (id);


--
-- Name: reminders reminders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reminders
    ADD CONSTRAINT reminders_pkey PRIMARY KEY (id);


--
-- Name: role_permissions role_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (id);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: sales_order_items sales_order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_order_items
    ADD CONSTRAINT sales_order_items_pkey PRIMARY KEY (id);


--
-- Name: sales_orders sales_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_pkey PRIMARY KEY (id);


--
-- Name: sales_quotes sales_quotes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_quotes
    ADD CONSTRAINT sales_quotes_pkey PRIMARY KEY (id);


--
-- Name: sales_return_items sales_return_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_return_items
    ADD CONSTRAINT sales_return_items_pkey PRIMARY KEY (id);


--
-- Name: sales_returns sales_returns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_returns
    ADD CONSTRAINT sales_returns_pkey PRIMARY KEY (id);


--
-- Name: settlement_requests settlement_requests_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settlement_requests
    ADD CONSTRAINT settlement_requests_idempotency_key_key UNIQUE (idempotency_key);


--
-- Name: settlement_requests settlement_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settlement_requests
    ADD CONSTRAINT settlement_requests_pkey PRIMARY KEY (id);


--
-- Name: shared_audit_log shared_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shared_audit_log
    ADD CONSTRAINT shared_audit_log_pkey PRIMARY KEY (id);


--
-- Name: stripe_payments stripe_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stripe_payments
    ADD CONSTRAINT stripe_payments_pkey PRIMARY KEY (id);


--
-- Name: stripe_webhook_events stripe_webhook_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stripe_webhook_events
    ADD CONSTRAINT stripe_webhook_events_pkey PRIMARY KEY (event_id);


--
-- Name: subscription_invoices subscription_invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_invoices
    ADD CONSTRAINT subscription_invoices_pkey PRIMARY KEY (id);


--
-- Name: subscription_requests subscription_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_requests
    ADD CONSTRAINT subscription_requests_pkey PRIMARY KEY (id);


--
-- Name: subscription_revenues subscription_revenues_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_revenues
    ADD CONSTRAINT subscription_revenues_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: suggestion_replies suggestion_replies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suggestion_replies
    ADD CONSTRAINT suggestion_replies_pkey PRIMARY KEY (id);


--
-- Name: suggestions suggestions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suggestions
    ADD CONSTRAINT suggestions_pkey PRIMARY KEY (id);


--
-- Name: supplier_bills supplier_bills_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_bills
    ADD CONSTRAINT supplier_bills_pkey PRIMARY KEY (id);


--
-- Name: supplier_payables supplier_payables_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_payables
    ADD CONSTRAINT supplier_payables_pkey PRIMARY KEY (id);


--
-- Name: suppliers suppliers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_pkey PRIMARY KEY (id);


--
-- Name: sync_batches sync_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_batches
    ADD CONSTRAINT sync_batches_pkey PRIMARY KEY (id);


--
-- Name: sync_logs sync_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_logs
    ADD CONSTRAINT sync_logs_pkey PRIMARY KEY (id);


--
-- Name: trash_items trash_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trash_items
    ADD CONSTRAINT trash_items_pkey PRIMARY KEY (id);


--
-- Name: app_notifications uq_app_notif_event; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_notifications
    ADD CONSTRAINT uq_app_notif_event UNIQUE (user_id, event_id);


--
-- Name: app_notifications uq_app_notif_source; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_notifications
    ADD CONSTRAINT uq_app_notif_source UNIQUE (organization_id, source_notif_id);


--
-- Name: product_barcodes uq_barcode_org_code; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_barcodes
    ADD CONSTRAINT uq_barcode_org_code UNIQUE (organization_id, barcode);


--
-- Name: branch_members uq_branch_member_org_user; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_members
    ADD CONSTRAINT uq_branch_member_org_user UNIQUE (organization_id, user_id);


--
-- Name: branches uq_branch_org_name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branches
    ADD CONSTRAINT uq_branch_org_name UNIQUE (organization_id, name);


--
-- Name: branch_stock uq_branch_stock_branch_product; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_stock
    ADD CONSTRAINT uq_branch_stock_branch_product UNIQUE (branch_id, product_id);


--
-- Name: branch_transfers uq_branch_transfer_idempotency; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_transfers
    ADD CONSTRAINT uq_branch_transfer_idempotency UNIQUE (organization_id, idempotency_key);


--
-- Name: branch_transfers uq_branch_transfer_number; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_transfers
    ADD CONSTRAINT uq_branch_transfer_number UNIQUE (organization_id, transfer_number);


--
-- Name: chat_messages uq_chat_sender_client; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT uq_chat_sender_client UNIQUE (sender_user_id, client_id);


--
-- Name: employee_invitations uq_employee_invite_state; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_invitations
    ADD CONSTRAINT uq_employee_invite_state UNIQUE (employee_id, invited_user_id, status);


--
-- Name: expiry_notifications uq_expiry_notif_org_product_day; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expiry_notifications
    ADD CONSTRAINT uq_expiry_notif_org_product_day UNIQUE (organization_id, product_id, notified_on);


--
-- Name: invoice_sequences uq_inv_seq_org_prefix_date; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_sequences
    ADD CONSTRAINT uq_inv_seq_org_prefix_date UNIQUE (organization_id, prefix, date);


--
-- Name: invoices uq_invoices_org_idempotency; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT uq_invoices_org_idempotency UNIQUE (organization_id, idempotency_key);


--
-- Name: invoices uq_invoices_org_number; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT uq_invoices_org_number UNIQUE (organization_id, invoice_number);


--
-- Name: merchant_links uq_merchant_link_party; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.merchant_links
    ADD CONSTRAINT uq_merchant_link_party UNIQUE (merchant_org_id, party_kind, party_id);


--
-- Name: org_invoice_designs uq_org_invoice_design_branch; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.org_invoice_designs
    ADD CONSTRAINT uq_org_invoice_design_branch UNIQUE (organization_id, branch_id, template_id);


--
-- Name: organizations uq_organization_slug; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT uq_organization_slug UNIQUE (slug);


--
-- Name: supplier_payables uq_payable_invoice; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_payables
    ADD CONSTRAINT uq_payable_invoice UNIQUE (invoice_id);


--
-- Name: pending_registrations uq_pending_registration_email; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_registrations
    ADD CONSTRAINT uq_pending_registration_email UNIQUE (email);


--
-- Name: product_prices uq_price_org_product_currency; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_prices
    ADD CONSTRAINT uq_price_org_product_currency UNIQUE (organization_id, product_id, currency);


--
-- Name: customer_receivables uq_receivable_invoice; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_receivables
    ADD CONSTRAINT uq_receivable_invoice UNIQUE (invoice_id);


--
-- Name: invoice_returns uq_returns_org_number; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_returns
    ADD CONSTRAINT uq_returns_org_number UNIQUE (organization_id, return_number);


--
-- Name: subscription_invoices uq_sub_inv_org_request; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_invoices
    ADD CONSTRAINT uq_sub_inv_org_request UNIQUE (organization_id, request_id);


--
-- Name: sync_batches uq_sync_batch_org_batch; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_batches
    ADD CONSTRAINT uq_sync_batch_org_batch UNIQUE (organization_id, batch_id, direction);


--
-- Name: product_units uq_unit_org_product_name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_units
    ADD CONSTRAINT uq_unit_org_product_name UNIQUE (organization_id, product_id, name);


--
-- Name: users uq_user_email; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT uq_user_email UNIQUE (email);


--
-- Name: users uq_user_firebase_uid; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT uq_user_firebase_uid UNIQUE (firebase_uid);


--
-- Name: users uq_users_public_code; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT uq_users_public_code UNIQUE (public_code);


--
-- Name: user_backup_keys user_backup_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_backup_keys
    ADD CONSTRAINT user_backup_keys_pkey PRIMARY KEY (user_id);


--
-- Name: user_backups user_backups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_backups
    ADD CONSTRAINT user_backups_pkey PRIMARY KEY (id);


--
-- Name: user_code_seq user_code_seq_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_code_seq
    ADD CONSTRAINT user_code_seq_pkey PRIMARY KEY (id);


--
-- Name: user_sessions user_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_sessions
    ADD CONSTRAINT user_sessions_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: warehouse_settings warehouse_settings_organization_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouse_settings
    ADD CONSTRAINT warehouse_settings_organization_id_key UNIQUE (organization_id);


--
-- Name: warehouse_settings warehouse_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouse_settings
    ADD CONSTRAINT warehouse_settings_pkey PRIMARY KEY (id);


--
-- Name: idx_org_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_org_name ON public.organizations USING btree (name);


--
-- Name: idx_org_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_org_status ON public.organizations USING btree (subscription_status);


--
-- Name: idx_users_org_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_org_role ON public.users USING btree (organization_id, role);


--
-- Name: ix_account_org_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_account_org_code ON public.accounts USING btree (organization_id, code);


--
-- Name: ix_admin_exchange_rates_currency_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ix_admin_exchange_rates_currency_code ON public.admin_exchange_rates USING btree (currency_code);


--
-- Name: ix_admin_operations_bank_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_admin_operations_bank_account_id ON public.admin_operations USING btree (bank_account_id);


--
-- Name: ix_admin_operations_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_admin_operations_created_at ON public.admin_operations USING btree (created_at);


--
-- Name: ix_agent_analytics_events_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_agent_analytics_events_created_at ON public.agent_analytics_events USING btree (created_at);


--
-- Name: ix_agent_analytics_events_org_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_agent_analytics_events_org_id ON public.agent_analytics_events USING btree (org_id);


--
-- Name: ix_agent_analytics_events_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_agent_analytics_events_user_id ON public.agent_analytics_events USING btree (user_id);


--
-- Name: ix_app_notif_domain_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_app_notif_domain_user ON public.app_notifications USING btree (domain, user_id);


--
-- Name: ix_app_notifications_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_app_notifications_created_at ON public.app_notifications USING btree (created_at);


--
-- Name: ix_app_notifications_is_read; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_app_notifications_is_read ON public.app_notifications USING btree (is_read);


--
-- Name: ix_app_notifications_is_system; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_app_notifications_is_system ON public.app_notifications USING btree (is_system);


--
-- Name: ix_app_notifications_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_app_notifications_organization_id ON public.app_notifications USING btree (organization_id);


--
-- Name: ix_app_notifications_source_notif_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_app_notifications_source_notif_id ON public.app_notifications USING btree (source_notif_id);


--
-- Name: ix_app_notifications_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_app_notifications_user_id ON public.app_notifications USING btree (user_id);


--
-- Name: ix_bank_accounts_bank_group_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_bank_accounts_bank_group_key ON public.bank_accounts USING btree (bank_group_key);


--
-- Name: ix_bank_accounts_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_bank_accounts_branch_id ON public.bank_accounts USING btree (branch_id);


--
-- Name: ix_bank_accounts_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_bank_accounts_organization_id ON public.bank_accounts USING btree (organization_id);


--
-- Name: ix_bank_transactions_bank_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_bank_transactions_bank_account_id ON public.bank_transactions USING btree (bank_account_id);


--
-- Name: ix_bank_transactions_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_bank_transactions_organization_id ON public.bank_transactions USING btree (organization_id);


--
-- Name: ix_branch_invitations_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_branch_invitations_branch_id ON public.branch_invitations USING btree (branch_id);


--
-- Name: ix_branch_invitations_invited_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_branch_invitations_invited_user_id ON public.branch_invitations USING btree (invited_user_id);


--
-- Name: ix_branch_invitations_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_branch_invitations_organization_id ON public.branch_invitations USING btree (organization_id);


--
-- Name: ix_branch_members_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_branch_members_organization_id ON public.branch_members USING btree (organization_id);


--
-- Name: ix_branch_members_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_branch_members_user_id ON public.branch_members USING btree (user_id);


--
-- Name: ix_branch_stock_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_branch_stock_branch_id ON public.branch_stock USING btree (branch_id);


--
-- Name: ix_branch_stock_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_branch_stock_organization_id ON public.branch_stock USING btree (organization_id);


--
-- Name: ix_branch_stock_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_branch_stock_product_id ON public.branch_stock USING btree (product_id);


--
-- Name: ix_branch_transfer_items_transfer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_branch_transfer_items_transfer_id ON public.branch_transfer_items USING btree (transfer_id);


--
-- Name: ix_branch_transfers_from_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_branch_transfers_from_branch_id ON public.branch_transfers USING btree (from_branch_id);


--
-- Name: ix_branch_transfers_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_branch_transfers_organization_id ON public.branch_transfers USING btree (organization_id);


--
-- Name: ix_branch_transfers_reversal_of_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_branch_transfers_reversal_of_id ON public.branch_transfers USING btree (reversal_of_id);


--
-- Name: ix_branch_transfers_to_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_branch_transfers_to_branch_id ON public.branch_transfers USING btree (to_branch_id);


--
-- Name: ix_branch_transfers_transfer_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_branch_transfers_transfer_number ON public.branch_transfers USING btree (transfer_number);


--
-- Name: ix_branches_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_branches_organization_id ON public.branches USING btree (organization_id);


--
-- Name: ix_categories_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_categories_org ON public.product_categories USING btree (organization_id);


--
-- Name: ix_chat_messages_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_chat_messages_created_at ON public.chat_messages USING btree (created_at);


--
-- Name: ix_chat_messages_link_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_chat_messages_link_id ON public.chat_messages USING btree (link_id);


--
-- Name: ix_chat_messages_merchant_org_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_chat_messages_merchant_org_id ON public.chat_messages USING btree (merchant_org_id);


--
-- Name: ix_chat_messages_recipient_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_chat_messages_recipient_user_id ON public.chat_messages USING btree (recipient_user_id);


--
-- Name: ix_chat_messages_sender_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_chat_messages_sender_user_id ON public.chat_messages USING btree (sender_user_id);


--
-- Name: ix_chat_presence_last_seen_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_chat_presence_last_seen_at ON public.chat_presence USING btree (last_seen_at);


--
-- Name: ix_cheques_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_cheques_organization_id ON public.cheques USING btree (organization_id);


--
-- Name: ix_customer_receivables_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_customer_receivables_customer_id ON public.customer_receivables USING btree (customer_id);


--
-- Name: ix_customer_receivables_invoice_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_customer_receivables_invoice_id ON public.customer_receivables USING btree (invoice_id);


--
-- Name: ix_customer_receivables_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_customer_receivables_organization_id ON public.customer_receivables USING btree (organization_id);


--
-- Name: ix_customers_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_customers_branch_id ON public.customers USING btree (branch_id);


--
-- Name: ix_customers_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_customers_org ON public.customers USING btree (organization_id);


--
-- Name: ix_customers_org_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_customers_org_name ON public.customers USING btree (organization_id, name);


--
-- Name: ix_debt_groups_org_party; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_debt_groups_org_party ON public.debt_groups USING btree (organization_id, party_kind, party_id);


--
-- Name: ix_device_tokens_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_device_tokens_token ON public.device_tokens USING btree (token);


--
-- Name: ix_device_tokens_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_device_tokens_user_id ON public.device_tokens USING btree (user_id);


--
-- Name: ix_dn_org_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_dn_org_number ON public.delivery_notes USING btree (organization_id, delivery_number);


--
-- Name: ix_employee_debts_emp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_employee_debts_emp ON public.employee_debts USING btree (employee_id);


--
-- Name: ix_employee_debts_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_employee_debts_org ON public.employee_debts USING btree (organization_id);


--
-- Name: ix_employee_invitations_emp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_employee_invitations_emp ON public.employee_invitations USING btree (employee_id);


--
-- Name: ix_employee_invitations_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_employee_invitations_org ON public.employee_invitations USING btree (organization_id);


--
-- Name: ix_employee_invitations_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_employee_invitations_user ON public.employee_invitations USING btree (invited_user_id);


--
-- Name: ix_employee_salary_emp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_employee_salary_emp ON public.employee_salary_payments USING btree (employee_id);


--
-- Name: ix_employee_salary_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_employee_salary_org ON public.employee_salary_payments USING btree (organization_id);


--
-- Name: ix_employee_workspace_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_employee_workspace_org ON public.employee_workspace USING btree (organization_id);


--
-- Name: ix_employee_workspace_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_employee_workspace_user ON public.employee_workspace USING btree (linked_user_id);


--
-- Name: ix_exchange_rate_history_currency_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_exchange_rate_history_currency_code ON public.exchange_rate_history USING btree (currency_code);


--
-- Name: ix_exchange_rate_history_effective_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_exchange_rate_history_effective_at ON public.exchange_rate_history USING btree (effective_at);


--
-- Name: ix_exchange_rate_store_currency_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ix_exchange_rate_store_currency_code ON public.exchange_rate_store USING btree (currency_code);


--
-- Name: ix_expenses_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_expenses_branch_id ON public.expenses USING btree (branch_id);


--
-- Name: ix_expenses_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_expenses_organization_id ON public.expenses USING btree (organization_id);


--
-- Name: ix_financial_payments_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_financial_payments_branch_id ON public.financial_payments USING btree (branch_id);


--
-- Name: ix_financial_payments_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_financial_payments_organization_id ON public.financial_payments USING btree (organization_id);


--
-- Name: ix_inv_seq_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_seq_org ON public.invoice_sequences USING btree (organization_id);


--
-- Name: ix_inv_seq_org_prefix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_seq_org_prefix ON public.invoice_sequences USING btree (organization_id, prefix, date);


--
-- Name: ix_inventory_created_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inventory_created_by ON public.inventory_movements USING btree (created_by);


--
-- Name: ix_inventory_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inventory_org ON public.inventory_movements USING btree (organization_id);


--
-- Name: ix_inventory_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inventory_product ON public.inventory_movements USING btree (organization_id, product_id, created_at);


--
-- Name: ix_invoice_item_changes_invoice_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoice_item_changes_invoice_id ON public.invoice_item_changes USING btree (invoice_id);


--
-- Name: ix_invoice_item_changes_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoice_item_changes_organization_id ON public.invoice_item_changes USING btree (organization_id);


--
-- Name: ix_invoice_items_invoice; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoice_items_invoice ON public.invoice_items USING btree (invoice_id);


--
-- Name: ix_invoice_items_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoice_items_product ON public.invoice_items USING btree (product_id);


--
-- Name: ix_invoice_items_unit_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoice_items_unit_id ON public.invoice_items USING btree (unit_id);


--
-- Name: ix_invoice_return_items_invoice_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoice_return_items_invoice_item_id ON public.invoice_return_items USING btree (invoice_item_id);


--
-- Name: ix_invoice_return_items_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoice_return_items_product_id ON public.invoice_return_items USING btree (product_id);


--
-- Name: ix_invoice_return_items_return_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoice_return_items_return_id ON public.invoice_return_items USING btree (return_id);


--
-- Name: ix_invoice_returns_created_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoice_returns_created_by ON public.invoice_returns USING btree (created_by);


--
-- Name: ix_invoice_returns_invoice_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoice_returns_invoice_id ON public.invoice_returns USING btree (invoice_id);


--
-- Name: ix_invoice_returns_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoice_returns_organization_id ON public.invoice_returns USING btree (organization_id);


--
-- Name: ix_invoice_returns_return_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoice_returns_return_number ON public.invoice_returns USING btree (return_number);


--
-- Name: ix_invoices_created_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoices_created_by ON public.invoices USING btree (created_by);


--
-- Name: ix_invoices_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoices_customer ON public.invoices USING btree (customer_id);


--
-- Name: ix_invoices_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoices_org ON public.invoices USING btree (organization_id);


--
-- Name: ix_invoices_org_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoices_org_number ON public.invoices USING btree (organization_id, invoice_number);


--
-- Name: ix_invoices_org_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoices_org_status ON public.invoices USING btree (organization_id, status);


--
-- Name: ix_invoices_supplier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_invoices_supplier ON public.invoices USING btree (supplier_id);


--
-- Name: ix_je_org_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_je_org_number ON public.journal_entries USING btree (organization_id, entry_number);


--
-- Name: ix_jel_entry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_jel_entry ON public.journal_entry_lines USING btree (journal_entry_id);


--
-- Name: ix_journal_entries_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_journal_entries_branch_id ON public.journal_entries USING btree (branch_id);


--
-- Name: ix_lots_org_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_lots_org_product ON public.inventory_lots USING btree (organization_id, product_id);


--
-- Name: ix_merchant_links_external_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_merchant_links_external_user ON public.merchant_links USING btree (external_user_id);


--
-- Name: ix_merchant_links_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_merchant_links_phone ON public.merchant_links USING btree (phone);


--
-- Name: ix_notification_preferences_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_notification_preferences_organization_id ON public.notification_preferences USING btree (organization_id);


--
-- Name: ix_notification_preferences_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_notification_preferences_user_id ON public.notification_preferences USING btree (user_id);


--
-- Name: ix_org_invoice_designs_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_org_invoice_designs_branch_id ON public.org_invoice_designs USING btree (branch_id);


--
-- Name: ix_org_invoice_designs_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_org_invoice_designs_organization_id ON public.org_invoice_designs USING btree (organization_id);


--
-- Name: ix_payments_bank_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_payments_bank_account_id ON public.payments USING btree (bank_account_id);


--
-- Name: ix_payments_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_payments_branch_id ON public.payments USING btree (branch_id);


--
-- Name: ix_payments_created_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_payments_created_by ON public.payments USING btree (created_by);


--
-- Name: ix_payments_invoice; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_payments_invoice ON public.payments USING btree (invoice_id);


--
-- Name: ix_payments_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_payments_org ON public.payments USING btree (organization_id);


--
-- Name: ix_payments_org_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_payments_org_status ON public.stripe_payments USING btree (organization_id, status);


--
-- Name: ix_pending_registrations_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pending_registrations_email ON public.pending_registrations USING btree (email);


--
-- Name: ix_personal_bank_accounts_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_bank_accounts_user_id ON public.personal_bank_accounts USING btree (user_id);


--
-- Name: ix_personal_budget_categories_budget_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_budget_categories_budget_id ON public.personal_budget_categories USING btree (budget_id);


--
-- Name: ix_personal_budget_categories_debt_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_budget_categories_debt_id ON public.personal_budget_categories USING btree (debt_id);


--
-- Name: ix_personal_budget_categories_goal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_budget_categories_goal_id ON public.personal_budget_categories USING btree (goal_id);


--
-- Name: ix_personal_budgets_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_budgets_user_id ON public.personal_budgets USING btree (user_id);


--
-- Name: ix_personal_debt_payments_budget_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_debt_payments_budget_id ON public.personal_debt_payments USING btree (budget_id);


--
-- Name: ix_personal_debt_payments_debt_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_debt_payments_debt_id ON public.personal_debt_payments USING btree (debt_id);


--
-- Name: ix_personal_debt_payments_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_debt_payments_user_id ON public.personal_debt_payments USING btree (user_id);


--
-- Name: ix_personal_debts_budget_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_debts_budget_id ON public.personal_debts USING btree (budget_id);


--
-- Name: ix_personal_debts_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_debts_user_id ON public.personal_debts USING btree (user_id);


--
-- Name: ix_personal_recurring_transactions_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_recurring_transactions_user_id ON public.personal_recurring_transactions USING btree (user_id);


--
-- Name: ix_personal_savings_goals_budget_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_savings_goals_budget_id ON public.personal_savings_goals USING btree (budget_id);


--
-- Name: ix_personal_savings_goals_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_savings_goals_user_id ON public.personal_savings_goals USING btree (user_id);


--
-- Name: ix_personal_transactions_bank_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_transactions_bank_account_id ON public.personal_transactions USING btree (bank_account_id);


--
-- Name: ix_personal_transactions_budget_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_transactions_budget_id ON public.personal_transactions USING btree (budget_id);


--
-- Name: ix_personal_transactions_client_op; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ix_personal_transactions_client_op ON public.personal_transactions USING btree (user_id, client_operation_id) WHERE (client_operation_id IS NOT NULL);


--
-- Name: ix_personal_transactions_client_operation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_transactions_client_operation_id ON public.personal_transactions USING btree (client_operation_id);


--
-- Name: ix_personal_transactions_debt_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_transactions_debt_id ON public.personal_transactions USING btree (debt_id);


--
-- Name: ix_personal_transactions_goal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_transactions_goal_id ON public.personal_transactions USING btree (goal_id);


--
-- Name: ix_personal_transactions_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_personal_transactions_user_id ON public.personal_transactions USING btree (user_id);


--
-- Name: ix_platform_notifications_sent_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_platform_notifications_sent_at ON public.platform_notifications USING btree (sent_at);


--
-- Name: ix_po_org_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_po_org_number ON public.purchase_orders USING btree (organization_id, order_number);


--
-- Name: ix_prec_org_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_prec_org_number ON public.purchase_receipts USING btree (organization_id, receipt_number);


--
-- Name: ix_product_barcodes_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_product_barcodes_organization_id ON public.product_barcodes USING btree (organization_id);


--
-- Name: ix_product_barcodes_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_product_barcodes_product_id ON public.product_barcodes USING btree (product_id);


--
-- Name: ix_product_barcodes_unit_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_product_barcodes_unit_id ON public.product_barcodes USING btree (unit_id);


--
-- Name: ix_product_units_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_product_units_organization_id ON public.product_units USING btree (organization_id);


--
-- Name: ix_product_units_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_product_units_product_id ON public.product_units USING btree (product_id);


--
-- Name: ix_products_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_products_branch_id ON public.products USING btree (branch_id);


--
-- Name: ix_products_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_products_category ON public.products USING btree (category_id);


--
-- Name: ix_products_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_products_org ON public.products USING btree (organization_id);


--
-- Name: ix_products_org_barcode; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_products_org_barcode ON public.products USING btree (organization_id, barcode);


--
-- Name: ix_products_org_branch_barcode; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_products_org_branch_barcode ON public.products USING btree (organization_id, branch_id, barcode);


--
-- Name: ix_products_org_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_products_org_name ON public.products USING btree (organization_id, name);


--
-- Name: ix_products_org_sku; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_products_org_sku ON public.products USING btree (organization_id, sku);


--
-- Name: ix_pur_org_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pur_org_number ON public.purchase_returns USING btree (organization_id, return_number);


--
-- Name: ix_purchase_return_items_invoice_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_purchase_return_items_invoice_item_id ON public.purchase_return_items USING btree (invoice_item_id);


--
-- Name: ix_purchase_returns_invoice_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_purchase_returns_invoice_id ON public.purchase_returns USING btree (invoice_id);


--
-- Name: ix_reconciliations_idem; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ix_reconciliations_idem ON public.reconciliations USING btree (idempotency_key);


--
-- Name: ix_reconciliations_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_reconciliations_org ON public.reconciliations USING btree (organization_id);


--
-- Name: ix_reconciliations_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_reconciliations_ref ON public.reconciliations USING btree (ref_code);


--
-- Name: ix_reminders_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_reminders_organization_id ON public.reminders USING btree (organization_id);


--
-- Name: ix_reminders_remind_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_reminders_remind_at ON public.reminders USING btree (remind_at);


--
-- Name: ix_reminders_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_reminders_user_id ON public.reminders USING btree (user_id);


--
-- Name: ix_role_perm_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_role_perm_role ON public.role_permissions USING btree (role_id);


--
-- Name: ix_sb_org_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_sb_org_number ON public.supplier_bills USING btree (organization_id, bill_number);


--
-- Name: ix_session_refresh; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_session_refresh ON public.user_sessions USING btree (refresh_token);


--
-- Name: ix_settlement_requests_org_party; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_settlement_requests_org_party ON public.settlement_requests USING btree (organization_id, party_kind, party_id);


--
-- Name: ix_shared_audit_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_shared_audit_org ON public.shared_audit_log USING btree (organization_id);


--
-- Name: ix_so_org_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_so_org_number ON public.sales_orders USING btree (organization_id, order_number);


--
-- Name: ix_so_org_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_so_org_status ON public.sales_orders USING btree (organization_id, status);


--
-- Name: ix_soi_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_soi_order ON public.sales_order_items USING btree (sales_order_id);


--
-- Name: ix_sq_org_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_sq_org_number ON public.sales_quotes USING btree (organization_id, quote_number);


--
-- Name: ix_sr_org_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_sr_org_number ON public.sales_returns USING btree (organization_id, return_number);


--
-- Name: ix_sri_return; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_sri_return ON public.sales_return_items USING btree (sales_return_id);


--
-- Name: ix_stripe_payments_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_stripe_payments_idempotency_key ON public.stripe_payments USING btree (idempotency_key);


--
-- Name: ix_stripe_payments_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_stripe_payments_organization_id ON public.stripe_payments USING btree (organization_id);


--
-- Name: ix_stripe_payments_plan_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_stripe_payments_plan_id ON public.stripe_payments USING btree (plan_id);


--
-- Name: ix_stripe_payments_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_stripe_payments_status ON public.stripe_payments USING btree (status);


--
-- Name: ix_stripe_payments_stripe_checkout_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_stripe_payments_stripe_checkout_session_id ON public.stripe_payments USING btree (stripe_checkout_session_id);


--
-- Name: ix_stripe_payments_stripe_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ix_stripe_payments_stripe_event_id ON public.stripe_payments USING btree (stripe_event_id);


--
-- Name: ix_stripe_payments_stripe_payment_intent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_stripe_payments_stripe_payment_intent_id ON public.stripe_payments USING btree (stripe_payment_intent_id);


--
-- Name: ix_stripe_payments_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_stripe_payments_user_id ON public.stripe_payments USING btree (user_id);


--
-- Name: ix_subscription_invoices_invoice_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ix_subscription_invoices_invoice_number ON public.subscription_invoices USING btree (invoice_number);


--
-- Name: ix_subscription_invoices_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscription_invoices_organization_id ON public.subscription_invoices USING btree (organization_id);


--
-- Name: ix_subscription_invoices_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscription_invoices_request_id ON public.subscription_invoices USING btree (request_id);


--
-- Name: ix_subscription_invoices_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscription_invoices_user_id ON public.subscription_invoices USING btree (user_id);


--
-- Name: ix_subscription_requests_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscription_requests_created_at ON public.subscription_requests USING btree (created_at);


--
-- Name: ix_subscription_requests_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscription_requests_organization_id ON public.subscription_requests USING btree (organization_id);


--
-- Name: ix_subscription_requests_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscription_requests_status ON public.subscription_requests USING btree (status);


--
-- Name: ix_subscription_requests_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscription_requests_user_id ON public.subscription_requests USING btree (user_id);


--
-- Name: ix_subscription_revenues_bank_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscription_revenues_bank_account_id ON public.subscription_revenues USING btree (bank_account_id);


--
-- Name: ix_subscription_revenues_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscription_revenues_created_at ON public.subscription_revenues USING btree (created_at);


--
-- Name: ix_subscription_revenues_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscription_revenues_organization_id ON public.subscription_revenues USING btree (organization_id);


--
-- Name: ix_subscription_revenues_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscription_revenues_request_id ON public.subscription_revenues USING btree (request_id);


--
-- Name: ix_subscription_revenues_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscription_revenues_user_id ON public.subscription_revenues USING btree (user_id);


--
-- Name: ix_subscriptions_org_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscriptions_org_status ON public.subscriptions USING btree (organization_id, status);


--
-- Name: ix_subscriptions_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscriptions_organization_id ON public.subscriptions USING btree (organization_id);


--
-- Name: ix_subscriptions_plan_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscriptions_plan_id ON public.subscriptions USING btree (plan_id);


--
-- Name: ix_subscriptions_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscriptions_status ON public.subscriptions USING btree (status);


--
-- Name: ix_subscriptions_stripe_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscriptions_stripe_customer_id ON public.subscriptions USING btree (stripe_customer_id);


--
-- Name: ix_subscriptions_stripe_sub; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscriptions_stripe_sub ON public.subscriptions USING btree (stripe_subscription_id);


--
-- Name: ix_subscriptions_stripe_subscription_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscriptions_stripe_subscription_id ON public.subscriptions USING btree (stripe_subscription_id);


--
-- Name: ix_subscriptions_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_subscriptions_user_id ON public.subscriptions USING btree (user_id);


--
-- Name: ix_suggestion_replies_suggestion_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_suggestion_replies_suggestion_id ON public.suggestion_replies USING btree (suggestion_id);


--
-- Name: ix_suggestion_replies_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_suggestion_replies_user_id ON public.suggestion_replies USING btree (user_id);


--
-- Name: ix_suggestions_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_suggestions_organization_id ON public.suggestions USING btree (organization_id);


--
-- Name: ix_suggestions_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_suggestions_user_id ON public.suggestions USING btree (user_id);


--
-- Name: ix_supplier_payables_invoice_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_supplier_payables_invoice_id ON public.supplier_payables USING btree (invoice_id);


--
-- Name: ix_supplier_payables_organization_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_supplier_payables_organization_id ON public.supplier_payables USING btree (organization_id);


--
-- Name: ix_supplier_payables_supplier_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_supplier_payables_supplier_id ON public.supplier_payables USING btree (supplier_id);


--
-- Name: ix_suppliers_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_suppliers_branch_id ON public.suppliers USING btree (branch_id);


--
-- Name: ix_suppliers_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_suppliers_org ON public.suppliers USING btree (organization_id);


--
-- Name: ix_suppliers_org_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_suppliers_org_name ON public.suppliers USING btree (organization_id, name);


--
-- Name: ix_trash_items_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_trash_items_created_at ON public.trash_items USING btree (created_at);


--
-- Name: ix_trash_items_item_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_trash_items_item_type ON public.trash_items USING btree (item_type);


--
-- Name: ix_trash_items_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_trash_items_status ON public.trash_items USING btree (status);


--
-- Name: ix_user_backups_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_user_backups_user_id ON public.user_backups USING btree (user_id);


--
-- Name: ix_user_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_user_email ON public.users USING btree (email);


--
-- Name: ix_user_firebase_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_user_firebase_uid ON public.users USING btree (firebase_uid);


--
-- Name: ix_user_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_user_org ON public.users USING btree (organization_id);


--
-- Name: ix_users_phone_lookup_digits; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_users_phone_lookup_digits ON public.users USING btree (phone_lookup_digits);


--
-- Name: ix_users_phone_national_digits; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_users_phone_national_digits ON public.users USING btree (phone_national_digits);


--
-- Name: ix_users_public_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_users_public_code ON public.users USING btree (public_code);


--
-- Name: uq_one_active_primary_per_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_one_active_primary_per_user ON public.user_sessions USING btree (user_id) WHERE ((is_active IS TRUE) AND (is_primary IS TRUE));


--
-- Name: uq_stripe_payments_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_stripe_payments_idempotency_key ON public.stripe_payments USING btree (idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: uq_sub_inv_provider_payment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_sub_inv_provider_payment ON public.subscription_invoices USING btree (provider_payment_id) WHERE (provider_payment_id IS NOT NULL);


--
-- Name: uq_sub_req_org_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_sub_req_org_pending ON public.subscription_requests USING btree (organization_id) WHERE ((status)::text = 'pending'::text);


--
-- Name: uq_sub_rev_provider_payment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_sub_rev_provider_payment ON public.subscription_revenues USING btree (provider_payment_id) WHERE (provider_payment_id IS NOT NULL);


--
-- Name: uq_sub_rev_request; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_sub_rev_request ON public.subscription_revenues USING btree (request_id) WHERE (request_id IS NOT NULL);


--
-- Name: uq_users_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_users_phone ON public.users USING btree (phone) WHERE ((phone IS NOT NULL) AND ((phone)::text <> ''::text));


--
-- Name: accounts accounts_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: accounts accounts_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.accounts(id) ON DELETE SET NULL;


--
-- Name: admin_exchange_rates admin_exchange_rates_changed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_exchange_rates
    ADD CONSTRAINT admin_exchange_rates_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: admin_operations admin_operations_bank_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_operations
    ADD CONSTRAINT admin_operations_bank_account_id_fkey FOREIGN KEY (bank_account_id) REFERENCES public.platform_bank_accounts(id) ON DELETE SET NULL;


--
-- Name: admin_permissions admin_permissions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_permissions
    ADD CONSTRAINT admin_permissions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: app_notifications app_notifications_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_notifications
    ADD CONSTRAINT app_notifications_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: bank_accounts bank_accounts_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_accounts
    ADD CONSTRAINT bank_accounts_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: bank_accounts bank_accounts_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_accounts
    ADD CONSTRAINT bank_accounts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: bank_transactions bank_transactions_bank_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_transactions
    ADD CONSTRAINT bank_transactions_bank_account_id_fkey FOREIGN KEY (bank_account_id) REFERENCES public.bank_accounts(id) ON DELETE CASCADE;


--
-- Name: bank_transactions bank_transactions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_transactions
    ADD CONSTRAINT bank_transactions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: branch_invitations branch_invitations_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_invitations
    ADD CONSTRAINT branch_invitations_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE CASCADE;


--
-- Name: branch_invitations branch_invitations_invited_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_invitations
    ADD CONSTRAINT branch_invitations_invited_by_fkey FOREIGN KEY (invited_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: branch_invitations branch_invitations_invited_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_invitations
    ADD CONSTRAINT branch_invitations_invited_user_id_fkey FOREIGN KEY (invited_user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: branch_invitations branch_invitations_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_invitations
    ADD CONSTRAINT branch_invitations_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: branch_members branch_members_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_members
    ADD CONSTRAINT branch_members_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: branch_members branch_members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_members
    ADD CONSTRAINT branch_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: branch_stock branch_stock_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_stock
    ADD CONSTRAINT branch_stock_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE CASCADE;


--
-- Name: branch_stock branch_stock_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_stock
    ADD CONSTRAINT branch_stock_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: branch_stock branch_stock_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_stock
    ADD CONSTRAINT branch_stock_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: branch_transfer_items branch_transfer_items_from_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_transfer_items
    ADD CONSTRAINT branch_transfer_items_from_product_id_fkey FOREIGN KEY (from_product_id) REFERENCES public.products(id) ON DELETE SET NULL;


--
-- Name: branch_transfer_items branch_transfer_items_from_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_transfer_items
    ADD CONSTRAINT branch_transfer_items_from_unit_id_fkey FOREIGN KEY (from_unit_id) REFERENCES public.product_units(id) ON DELETE SET NULL;


--
-- Name: branch_transfer_items branch_transfer_items_to_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_transfer_items
    ADD CONSTRAINT branch_transfer_items_to_product_id_fkey FOREIGN KEY (to_product_id) REFERENCES public.products(id) ON DELETE SET NULL;


--
-- Name: branch_transfer_items branch_transfer_items_to_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_transfer_items
    ADD CONSTRAINT branch_transfer_items_to_unit_id_fkey FOREIGN KEY (to_unit_id) REFERENCES public.product_units(id) ON DELETE SET NULL;


--
-- Name: branch_transfer_items branch_transfer_items_transfer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_transfer_items
    ADD CONSTRAINT branch_transfer_items_transfer_id_fkey FOREIGN KEY (transfer_id) REFERENCES public.branch_transfers(id) ON DELETE CASCADE;


--
-- Name: branch_transfers branch_transfers_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_transfers
    ADD CONSTRAINT branch_transfers_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: branch_transfers branch_transfers_from_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_transfers
    ADD CONSTRAINT branch_transfers_from_account_id_fkey FOREIGN KEY (from_account_id) REFERENCES public.bank_accounts(id) ON DELETE SET NULL;


--
-- Name: branch_transfers branch_transfers_from_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_transfers
    ADD CONSTRAINT branch_transfers_from_branch_id_fkey FOREIGN KEY (from_branch_id) REFERENCES public.branches(id) ON DELETE RESTRICT;


--
-- Name: branch_transfers branch_transfers_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_transfers
    ADD CONSTRAINT branch_transfers_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: branch_transfers branch_transfers_reversal_of_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_transfers
    ADD CONSTRAINT branch_transfers_reversal_of_id_fkey FOREIGN KEY (reversal_of_id) REFERENCES public.branch_transfers(id) ON DELETE SET NULL;


--
-- Name: branch_transfers branch_transfers_to_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_transfers
    ADD CONSTRAINT branch_transfers_to_account_id_fkey FOREIGN KEY (to_account_id) REFERENCES public.bank_accounts(id) ON DELETE SET NULL;


--
-- Name: branch_transfers branch_transfers_to_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_transfers
    ADD CONSTRAINT branch_transfers_to_branch_id_fkey FOREIGN KEY (to_branch_id) REFERENCES public.branches(id) ON DELETE RESTRICT;


--
-- Name: branches branches_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branches
    ADD CONSTRAINT branches_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: business_project_backups business_project_backups_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_project_backups
    ADD CONSTRAINT business_project_backups_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: business_project_settings business_project_settings_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_project_settings
    ADD CONSTRAINT business_project_settings_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: cheques cheques_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cheques
    ADD CONSTRAINT cheques_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: customer_receivables customer_receivables_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_receivables
    ADD CONSTRAINT customer_receivables_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- Name: customer_receivables customer_receivables_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_receivables
    ADD CONSTRAINT customer_receivables_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE CASCADE;


--
-- Name: customer_receivables customer_receivables_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_receivables
    ADD CONSTRAINT customer_receivables_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: customers customers_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: customers customers_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: delivery_note_items delivery_note_items_delivery_note_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_note_items
    ADD CONSTRAINT delivery_note_items_delivery_note_id_fkey FOREIGN KEY (delivery_note_id) REFERENCES public.delivery_notes(id) ON DELETE CASCADE;


--
-- Name: delivery_note_items delivery_note_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_note_items
    ADD CONSTRAINT delivery_note_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE SET NULL;


--
-- Name: delivery_notes delivery_notes_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_notes
    ADD CONSTRAINT delivery_notes_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: delivery_notes delivery_notes_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_notes
    ADD CONSTRAINT delivery_notes_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE SET NULL;


--
-- Name: delivery_notes delivery_notes_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_notes
    ADD CONSTRAINT delivery_notes_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: delivery_notes delivery_notes_sales_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_notes
    ADD CONSTRAINT delivery_notes_sales_order_id_fkey FOREIGN KEY (sales_order_id) REFERENCES public.sales_orders(id) ON DELETE SET NULL;


--
-- Name: employee_debts employee_debts_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_debts
    ADD CONSTRAINT employee_debts_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: employee_debts employee_debts_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_debts
    ADD CONSTRAINT employee_debts_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE;


--
-- Name: employee_debts employee_debts_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_debts
    ADD CONSTRAINT employee_debts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: employee_invitations employee_invitations_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_invitations
    ADD CONSTRAINT employee_invitations_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE;


--
-- Name: employee_invitations employee_invitations_invited_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_invitations
    ADD CONSTRAINT employee_invitations_invited_by_fkey FOREIGN KEY (invited_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: employee_invitations employee_invitations_invited_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_invitations
    ADD CONSTRAINT employee_invitations_invited_user_id_fkey FOREIGN KEY (invited_user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: employee_invitations employee_invitations_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_invitations
    ADD CONSTRAINT employee_invitations_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: employee_salary_payments employee_salary_payments_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_salary_payments
    ADD CONSTRAINT employee_salary_payments_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: employee_salary_payments employee_salary_payments_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_salary_payments
    ADD CONSTRAINT employee_salary_payments_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE;


--
-- Name: employee_salary_payments employee_salary_payments_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_salary_payments
    ADD CONSTRAINT employee_salary_payments_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: employee_workspace employee_workspace_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_workspace
    ADD CONSTRAINT employee_workspace_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE;


--
-- Name: employee_workspace employee_workspace_linked_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_workspace
    ADD CONSTRAINT employee_workspace_linked_user_id_fkey FOREIGN KEY (linked_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: employee_workspace employee_workspace_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_workspace
    ADD CONSTRAINT employee_workspace_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: exchange_rate_history exchange_rate_history_changed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_rate_history
    ADD CONSTRAINT exchange_rate_history_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: expenses expenses_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: expenses expenses_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: expiry_notifications expiry_notifications_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expiry_notifications
    ADD CONSTRAINT expiry_notifications_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: expiry_notifications expiry_notifications_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expiry_notifications
    ADD CONSTRAINT expiry_notifications_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: financial_payments financial_payments_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_payments
    ADD CONSTRAINT financial_payments_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: financial_payments financial_payments_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_payments
    ADD CONSTRAINT financial_payments_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: expenses fk_expenses_bank_account; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT fk_expenses_bank_account FOREIGN KEY (bank_account_id) REFERENCES public.bank_accounts(id) ON DELETE SET NULL;


--
-- Name: invoice_items fk_invoice_items_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_items
    ADD CONSTRAINT fk_invoice_items_unit FOREIGN KEY (unit_id) REFERENCES public.product_units(id) ON DELETE SET NULL;


--
-- Name: invoices fk_invoices_branch; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT fk_invoices_branch FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: payments fk_payments_bank_account; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT fk_payments_bank_account FOREIGN KEY (bank_account_id) REFERENCES public.bank_accounts(id) ON DELETE SET NULL;


--
-- Name: inventory_lot_consumptions inventory_lot_consumptions_invoice_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_lot_consumptions
    ADD CONSTRAINT inventory_lot_consumptions_invoice_item_id_fkey FOREIGN KEY (invoice_item_id) REFERENCES public.invoice_items(id) ON DELETE CASCADE;


--
-- Name: inventory_lot_consumptions inventory_lot_consumptions_lot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_lot_consumptions
    ADD CONSTRAINT inventory_lot_consumptions_lot_id_fkey FOREIGN KEY (lot_id) REFERENCES public.inventory_lots(id) ON DELETE CASCADE;


--
-- Name: inventory_lot_consumptions inventory_lot_consumptions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_lot_consumptions
    ADD CONSTRAINT inventory_lot_consumptions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: inventory_lots inventory_lots_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_lots
    ADD CONSTRAINT inventory_lots_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: inventory_lots inventory_lots_invoice_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_lots
    ADD CONSTRAINT inventory_lots_invoice_item_id_fkey FOREIGN KEY (invoice_item_id) REFERENCES public.invoice_items(id) ON DELETE SET NULL;


--
-- Name: inventory_lots inventory_lots_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_lots
    ADD CONSTRAINT inventory_lots_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: inventory_lots inventory_lots_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_lots
    ADD CONSTRAINT inventory_lots_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: inventory_lots inventory_lots_purchase_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_lots
    ADD CONSTRAINT inventory_lots_purchase_invoice_id_fkey FOREIGN KEY (purchase_invoice_id) REFERENCES public.invoices(id) ON DELETE SET NULL;


--
-- Name: inventory_lots inventory_lots_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_lots
    ADD CONSTRAINT inventory_lots_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE SET NULL;


--
-- Name: inventory_lots inventory_lots_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_lots
    ADD CONSTRAINT inventory_lots_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.product_units(id) ON DELETE SET NULL;


--
-- Name: inventory_movements inventory_movements_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_movements
    ADD CONSTRAINT inventory_movements_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: inventory_movements inventory_movements_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_movements
    ADD CONSTRAINT inventory_movements_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: inventory_movements inventory_movements_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_movements
    ADD CONSTRAINT inventory_movements_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: inventory_movements inventory_movements_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_movements
    ADD CONSTRAINT inventory_movements_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: invoice_item_changes invoice_item_changes_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_item_changes
    ADD CONSTRAINT invoice_item_changes_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE CASCADE;


--
-- Name: invoice_item_changes invoice_item_changes_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_item_changes
    ADD CONSTRAINT invoice_item_changes_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: invoice_items invoice_items_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_items
    ADD CONSTRAINT invoice_items_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE CASCADE;


--
-- Name: invoice_items invoice_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_items
    ADD CONSTRAINT invoice_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE SET NULL;


--
-- Name: invoice_return_items invoice_return_items_invoice_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_return_items
    ADD CONSTRAINT invoice_return_items_invoice_item_id_fkey FOREIGN KEY (invoice_item_id) REFERENCES public.invoice_items(id) ON DELETE SET NULL;


--
-- Name: invoice_return_items invoice_return_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_return_items
    ADD CONSTRAINT invoice_return_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE SET NULL;


--
-- Name: invoice_return_items invoice_return_items_return_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_return_items
    ADD CONSTRAINT invoice_return_items_return_id_fkey FOREIGN KEY (return_id) REFERENCES public.invoice_returns(id) ON DELETE CASCADE;


--
-- Name: invoice_returns invoice_returns_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_returns
    ADD CONSTRAINT invoice_returns_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: invoice_returns invoice_returns_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_returns
    ADD CONSTRAINT invoice_returns_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE CASCADE;


--
-- Name: invoice_returns invoice_returns_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_returns
    ADD CONSTRAINT invoice_returns_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: invoice_sequences invoice_sequences_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice_sequences
    ADD CONSTRAINT invoice_sequences_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: invoices invoices_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: invoices invoices_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE SET NULL;


--
-- Name: invoices invoices_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: invoices invoices_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE SET NULL;


--
-- Name: journal_entries journal_entries_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: journal_entries journal_entries_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: journal_entries journal_entries_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: journal_entry_lines journal_entry_lines_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entry_lines
    ADD CONSTRAINT journal_entry_lines_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE RESTRICT;


--
-- Name: journal_entry_lines journal_entry_lines_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entry_lines
    ADD CONSTRAINT journal_entry_lines_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE CASCADE;


--
-- Name: notification_preferences notification_preferences_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_preferences
    ADD CONSTRAINT notification_preferences_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: org_invoice_designs org_invoice_designs_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.org_invoice_designs
    ADD CONSTRAINT org_invoice_designs_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE CASCADE;


--
-- Name: org_invoice_designs org_invoice_designs_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.org_invoice_designs
    ADD CONSTRAINT org_invoice_designs_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: payments payments_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: payments payments_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: payments payments_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE CASCADE;


--
-- Name: payments payments_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: personal_bank_accounts personal_bank_accounts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_bank_accounts
    ADD CONSTRAINT personal_bank_accounts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: personal_budget_categories personal_budget_categories_budget_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_budget_categories
    ADD CONSTRAINT personal_budget_categories_budget_id_fkey FOREIGN KEY (budget_id) REFERENCES public.personal_budgets(id) ON DELETE CASCADE;


--
-- Name: personal_budget_categories personal_budget_categories_debt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_budget_categories
    ADD CONSTRAINT personal_budget_categories_debt_id_fkey FOREIGN KEY (debt_id) REFERENCES public.personal_debts(id) ON DELETE SET NULL;


--
-- Name: personal_budget_categories personal_budget_categories_goal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_budget_categories
    ADD CONSTRAINT personal_budget_categories_goal_id_fkey FOREIGN KEY (goal_id) REFERENCES public.personal_savings_goals(id) ON DELETE SET NULL;


--
-- Name: personal_budgets personal_budgets_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_budgets
    ADD CONSTRAINT personal_budgets_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: personal_debt_payments personal_debt_payments_budget_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_debt_payments
    ADD CONSTRAINT personal_debt_payments_budget_id_fkey FOREIGN KEY (budget_id) REFERENCES public.personal_budgets(id) ON DELETE SET NULL;


--
-- Name: personal_debt_payments personal_debt_payments_debt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_debt_payments
    ADD CONSTRAINT personal_debt_payments_debt_id_fkey FOREIGN KEY (debt_id) REFERENCES public.personal_debts(id) ON DELETE CASCADE;


--
-- Name: personal_debt_payments personal_debt_payments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_debt_payments
    ADD CONSTRAINT personal_debt_payments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: personal_debts personal_debts_budget_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_debts
    ADD CONSTRAINT personal_debts_budget_id_fkey FOREIGN KEY (budget_id) REFERENCES public.personal_budgets(id) ON DELETE SET NULL;


--
-- Name: personal_debts personal_debts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_debts
    ADD CONSTRAINT personal_debts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: personal_recurring_transactions personal_recurring_transactions_bank_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_recurring_transactions
    ADD CONSTRAINT personal_recurring_transactions_bank_account_id_fkey FOREIGN KEY (bank_account_id) REFERENCES public.personal_bank_accounts(id) ON DELETE SET NULL;


--
-- Name: personal_recurring_transactions personal_recurring_transactions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_recurring_transactions
    ADD CONSTRAINT personal_recurring_transactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: personal_savings_goals personal_savings_goals_budget_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_savings_goals
    ADD CONSTRAINT personal_savings_goals_budget_id_fkey FOREIGN KEY (budget_id) REFERENCES public.personal_budgets(id) ON DELETE SET NULL;


--
-- Name: personal_savings_goals personal_savings_goals_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_savings_goals
    ADD CONSTRAINT personal_savings_goals_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: personal_transactions personal_transactions_bank_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_transactions
    ADD CONSTRAINT personal_transactions_bank_account_id_fkey FOREIGN KEY (bank_account_id) REFERENCES public.personal_bank_accounts(id) ON DELETE SET NULL;


--
-- Name: personal_transactions personal_transactions_budget_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_transactions
    ADD CONSTRAINT personal_transactions_budget_category_id_fkey FOREIGN KEY (budget_category_id) REFERENCES public.personal_budget_categories(id) ON DELETE SET NULL;


--
-- Name: personal_transactions personal_transactions_budget_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_transactions
    ADD CONSTRAINT personal_transactions_budget_id_fkey FOREIGN KEY (budget_id) REFERENCES public.personal_budgets(id) ON DELETE SET NULL;


--
-- Name: personal_transactions personal_transactions_debt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_transactions
    ADD CONSTRAINT personal_transactions_debt_id_fkey FOREIGN KEY (debt_id) REFERENCES public.personal_debts(id) ON DELETE SET NULL;


--
-- Name: personal_transactions personal_transactions_goal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_transactions
    ADD CONSTRAINT personal_transactions_goal_id_fkey FOREIGN KEY (goal_id) REFERENCES public.personal_savings_goals(id) ON DELETE SET NULL;


--
-- Name: personal_transactions personal_transactions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_transactions
    ADD CONSTRAINT personal_transactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: product_barcodes product_barcodes_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_barcodes
    ADD CONSTRAINT product_barcodes_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: product_barcodes product_barcodes_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_barcodes
    ADD CONSTRAINT product_barcodes_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: product_barcodes product_barcodes_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_barcodes
    ADD CONSTRAINT product_barcodes_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.product_units(id) ON DELETE SET NULL;


--
-- Name: product_categories product_categories_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_categories
    ADD CONSTRAINT product_categories_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: product_prices product_prices_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_prices
    ADD CONSTRAINT product_prices_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: product_prices product_prices_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_prices
    ADD CONSTRAINT product_prices_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: product_units product_units_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_units
    ADD CONSTRAINT product_units_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: product_units product_units_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_units
    ADD CONSTRAINT product_units_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: products products_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: products products_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.product_categories(id) ON DELETE SET NULL;


--
-- Name: products products_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: purchase_order_items purchase_order_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_items
    ADD CONSTRAINT purchase_order_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE SET NULL;


--
-- Name: purchase_order_items purchase_order_items_purchase_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_items
    ADD CONSTRAINT purchase_order_items_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id) ON DELETE CASCADE;


--
-- Name: purchase_orders purchase_orders_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: purchase_orders purchase_orders_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: purchase_orders purchase_orders_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE SET NULL;


--
-- Name: purchase_receipt_items purchase_receipt_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_receipt_items
    ADD CONSTRAINT purchase_receipt_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE SET NULL;


--
-- Name: purchase_receipt_items purchase_receipt_items_purchase_receipt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_receipt_items
    ADD CONSTRAINT purchase_receipt_items_purchase_receipt_id_fkey FOREIGN KEY (purchase_receipt_id) REFERENCES public.purchase_receipts(id) ON DELETE CASCADE;


--
-- Name: purchase_receipts purchase_receipts_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_receipts
    ADD CONSTRAINT purchase_receipts_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: purchase_receipts purchase_receipts_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_receipts
    ADD CONSTRAINT purchase_receipts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: purchase_receipts purchase_receipts_purchase_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_receipts
    ADD CONSTRAINT purchase_receipts_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id) ON DELETE SET NULL;


--
-- Name: purchase_receipts purchase_receipts_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_receipts
    ADD CONSTRAINT purchase_receipts_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE SET NULL;


--
-- Name: purchase_return_items purchase_return_items_invoice_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_return_items
    ADD CONSTRAINT purchase_return_items_invoice_item_id_fkey FOREIGN KEY (invoice_item_id) REFERENCES public.invoice_items(id) ON DELETE SET NULL;


--
-- Name: purchase_return_items purchase_return_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_return_items
    ADD CONSTRAINT purchase_return_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE SET NULL;


--
-- Name: purchase_return_items purchase_return_items_purchase_return_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_return_items
    ADD CONSTRAINT purchase_return_items_purchase_return_id_fkey FOREIGN KEY (purchase_return_id) REFERENCES public.purchase_returns(id) ON DELETE CASCADE;


--
-- Name: purchase_returns purchase_returns_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_returns
    ADD CONSTRAINT purchase_returns_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: purchase_returns purchase_returns_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_returns
    ADD CONSTRAINT purchase_returns_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE CASCADE;


--
-- Name: purchase_returns purchase_returns_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_returns
    ADD CONSTRAINT purchase_returns_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: purchase_returns purchase_returns_purchase_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_returns
    ADD CONSTRAINT purchase_returns_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id) ON DELETE SET NULL;


--
-- Name: purchase_returns purchase_returns_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_returns
    ADD CONSTRAINT purchase_returns_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE SET NULL;


--
-- Name: quote_items quote_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quote_items
    ADD CONSTRAINT quote_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE SET NULL;


--
-- Name: quote_items quote_items_quote_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quote_items
    ADD CONSTRAINT quote_items_quote_id_fkey FOREIGN KEY (quote_id) REFERENCES public.sales_quotes(id) ON DELETE CASCADE;


--
-- Name: reconciliations reconciliations_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliations
    ADD CONSTRAINT reconciliations_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: reconciliations reconciliations_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliations
    ADD CONSTRAINT reconciliations_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: reconciliations reconciliations_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliations
    ADD CONSTRAINT reconciliations_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: reconciliations reconciliations_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliations
    ADD CONSTRAINT reconciliations_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: reminders reminders_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reminders
    ADD CONSTRAINT reminders_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: role_permissions role_permissions_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE;


--
-- Name: roles roles_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: sales_order_items sales_order_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_order_items
    ADD CONSTRAINT sales_order_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE SET NULL;


--
-- Name: sales_order_items sales_order_items_sales_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_order_items
    ADD CONSTRAINT sales_order_items_sales_order_id_fkey FOREIGN KEY (sales_order_id) REFERENCES public.sales_orders(id) ON DELETE CASCADE;


--
-- Name: sales_orders sales_orders_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: sales_orders sales_orders_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE SET NULL;


--
-- Name: sales_orders sales_orders_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_orders
    ADD CONSTRAINT sales_orders_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: sales_quotes sales_quotes_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_quotes
    ADD CONSTRAINT sales_quotes_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: sales_quotes sales_quotes_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_quotes
    ADD CONSTRAINT sales_quotes_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE SET NULL;


--
-- Name: sales_quotes sales_quotes_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_quotes
    ADD CONSTRAINT sales_quotes_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: sales_return_items sales_return_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_return_items
    ADD CONSTRAINT sales_return_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE SET NULL;


--
-- Name: sales_return_items sales_return_items_sales_return_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_return_items
    ADD CONSTRAINT sales_return_items_sales_return_id_fkey FOREIGN KEY (sales_return_id) REFERENCES public.sales_returns(id) ON DELETE CASCADE;


--
-- Name: sales_returns sales_returns_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_returns
    ADD CONSTRAINT sales_returns_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: sales_returns sales_returns_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_returns
    ADD CONSTRAINT sales_returns_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE SET NULL;


--
-- Name: sales_returns sales_returns_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_returns
    ADD CONSTRAINT sales_returns_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: sales_returns sales_returns_sales_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_returns
    ADD CONSTRAINT sales_returns_sales_order_id_fkey FOREIGN KEY (sales_order_id) REFERENCES public.sales_orders(id) ON DELETE SET NULL;


--
-- Name: stripe_payments stripe_payments_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stripe_payments
    ADD CONSTRAINT stripe_payments_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: stripe_payments stripe_payments_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stripe_payments
    ADD CONSTRAINT stripe_payments_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES public.plans(id) ON DELETE SET NULL;


--
-- Name: stripe_payments stripe_payments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stripe_payments
    ADD CONSTRAINT stripe_payments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: subscription_invoices subscription_invoices_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_invoices
    ADD CONSTRAINT subscription_invoices_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: subscription_invoices subscription_invoices_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_invoices
    ADD CONSTRAINT subscription_invoices_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.subscription_requests(id) ON DELETE SET NULL;


--
-- Name: subscription_invoices subscription_invoices_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_invoices
    ADD CONSTRAINT subscription_invoices_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: subscription_revenues subscription_revenues_bank_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_revenues
    ADD CONSTRAINT subscription_revenues_bank_account_id_fkey FOREIGN KEY (bank_account_id) REFERENCES public.platform_bank_accounts(id) ON DELETE SET NULL;


--
-- Name: subscription_revenues subscription_revenues_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_revenues
    ADD CONSTRAINT subscription_revenues_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.subscription_requests(id) ON DELETE SET NULL;


--
-- Name: subscriptions subscriptions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: subscriptions subscriptions_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES public.plans(id) ON DELETE SET NULL;


--
-- Name: subscriptions subscriptions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: suggestion_replies suggestion_replies_suggestion_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suggestion_replies
    ADD CONSTRAINT suggestion_replies_suggestion_id_fkey FOREIGN KEY (suggestion_id) REFERENCES public.suggestions(id) ON DELETE CASCADE;


--
-- Name: supplier_bills supplier_bills_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_bills
    ADD CONSTRAINT supplier_bills_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: supplier_bills supplier_bills_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_bills
    ADD CONSTRAINT supplier_bills_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: supplier_bills supplier_bills_purchase_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_bills
    ADD CONSTRAINT supplier_bills_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id) ON DELETE SET NULL;


--
-- Name: supplier_bills supplier_bills_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_bills
    ADD CONSTRAINT supplier_bills_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE SET NULL;


--
-- Name: supplier_payables supplier_payables_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_payables
    ADD CONSTRAINT supplier_payables_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE CASCADE;


--
-- Name: supplier_payables supplier_payables_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_payables
    ADD CONSTRAINT supplier_payables_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: supplier_payables supplier_payables_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_payables
    ADD CONSTRAINT supplier_payables_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE CASCADE;


--
-- Name: suppliers suppliers_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: suppliers suppliers_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: user_backup_keys user_backup_keys_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_backup_keys
    ADD CONSTRAINT user_backup_keys_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_backups user_backups_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_backups
    ADD CONSTRAINT user_backups_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_sessions user_sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_sessions
    ADD CONSTRAINT user_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: users users_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: warehouse_settings warehouse_settings_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouse_settings
    ADD CONSTRAINT warehouse_settings_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict QA0kKf92rzhSNUAKfF5dKazXyOIAjr3U2SqFifXacpcF0rvcMhBlgsZlxMfP4rt

