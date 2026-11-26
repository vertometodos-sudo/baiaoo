-- =====================================================================
--  Métricas confiáveis: cliques sem fraude, visitas e estatísticas
--  - O navegador não consegue mais escolher data, URL ou id do clique.
--  - A URL do clique passa a ser a do botão salvo no perfil (link_idx).
--  - Cliques e visitas repetidos do mesmo aparelho são ignorados.
--  - Nenhum IP é guardado: só um código (hash) que muda todo dia.
--  - Nova tabela "visitas" e função "stats_perfil" para o painel.
-- =====================================================================

-- sal secreto do hash (fica fora da API)
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.config (k text primary key, v text not null);
insert into private.config (k, v)
  values ('sal_hash', encode(extensions.gen_random_bytes(32), 'hex'))
  on conflict (k) do nothing;

-- código anônimo do visitante: muda por dia e por perfil, sem guardar IP
create or replace function private.visitante_hash(p_profile uuid)
returns text language plpgsql stable security definer set search_path = '' as $$
declare h json; ip text; ua text;
begin
  begin h := current_setting('request.headers', true)::json; exception when others then h := null; end;
  if h is null then return null; end if;
  ip := trim(split_part(coalesce(h->>'cf-connecting-ip', h->>'x-real-ip', h->>'x-forwarded-for', ''), ',', 1));
  if ip = '' then return null; end if;
  ua := coalesce(h->>'user-agent', '');
  return left(encode(extensions.digest(
    (select v from private.config where k = 'sal_hash') || '|' || ip || '|' || ua || '|' ||
    p_profile::text || '|' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD'),
    'sha256'), 'hex'), 32);
end $$;

-- ---------------------------------------------------------------- cliques
alter table public.cliques add column if not exists visitante text;

revoke insert on public.cliques from anon, authenticated;
grant insert (profile_id, link_idx, url, utm_source) on public.cliques to anon, authenticated;

create or replace function public.cliques_antes()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_links jsonb;
begin
  select p.links into v_links from public.profiles p where p.id = new.profile_id and p.ativo;
  if v_links is null or jsonb_typeof(v_links) <> 'array' then return null; end if;
  if new.link_idx is null or new.link_idx < 0 or new.link_idx >= jsonb_array_length(v_links) then return null; end if;
  new.url        := v_links -> new.link_idx ->> 'url';          -- URL real do botão
  new.utm_source := left(nullif(lower(trim(new.utm_source)), ''), 40);
  new.created_at := now();
  new.visitante  := private.visitante_hash(new.profile_id);
  if new.visitante is not null and exists (
       select 1 from public.cliques c
        where c.profile_id = new.profile_id and c.link_idx = new.link_idx
          and c.visitante = new.visitante and c.created_at > now() - interval '30 seconds') then
    return null;                                                 -- clique repetido: ignora
  end if;
  return new;
end $$;

drop trigger if exists cliques_antes on public.cliques;
create trigger cliques_antes before insert on public.cliques
  for each row execute function public.cliques_antes();

-- ---------------------------------------------------------------- visitas
create table if not exists public.visitas (
  id          bigint generated always as identity primary key,
  profile_id  uuid not null references public.profiles(id) on delete cascade,
  utm_source  text,
  visitante   text,
  created_at  timestamptz not null default now()
);
create index if not exists visitas_profile_data on public.visitas (profile_id, created_at desc);
alter table public.visitas enable row level security;

revoke all on public.visitas from anon, authenticated;
grant insert (profile_id, utm_source) on public.visitas to anon, authenticated;
grant select on public.visitas to authenticated;

drop policy if exists "registrar visita" on public.visitas;
create policy "registrar visita" on public.visitas for insert to anon, authenticated
  with check (exists (select 1 from public.profiles p where p.id = visitas.profile_id and p.ativo));
drop policy if exists "ver visitas" on public.visitas;
create policy "ver visitas" on public.visitas for select to authenticated
  using (profile_id = auth.uid() or public.is_master());

create or replace function public.visitas_antes()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.utm_source := left(nullif(lower(trim(new.utm_source)), ''), 40);
  new.created_at := now();
  new.visitante  := private.visitante_hash(new.profile_id);
  if new.visitante is not null and exists (
       select 1 from public.visitas v
        where v.profile_id = new.profile_id and v.visitante = new.visitante
          and v.created_at > now() - interval '30 minutes') then
    return null;                                                 -- mesma pessoa recarregando
  end if;
  return new;
end $$;

drop trigger if exists visitas_antes on public.visitas;
create trigger visitas_antes before insert on public.visitas
  for each row execute function public.visitas_antes();

-- ---------------------------------------------------------- estatísticas
create or replace function public.stats_perfil(p_id uuid, p_dias int default 30)
returns json language plpgsql stable security definer set search_path = '' as $$
declare desde timestamptz; hoje timestamptz; r json;
begin
  if p_id is null or not (p_id = auth.uid() or public.is_master()) then
    raise exception 'sem permissao';
  end if;
  p_dias := least(greatest(coalesce(p_dias, 30), 1), 365);
  desde  := now() - make_interval(days => p_dias);
  hoje   := date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  select json_build_object(
    'dias',          p_dias,
    'visitas',       (select count(*) from public.visitas where profile_id = p_id and created_at >= desde),
    'visitas_hoje',  (select count(*) from public.visitas where profile_id = p_id and created_at >= hoje),
    'pessoas',       (select count(distinct coalesce(visitante, id::text)) from public.visitas where profile_id = p_id and created_at >= desde),
    'cliques',       (select count(*) from public.cliques where profile_id = p_id and created_at >= desde),
    'cliques_hoje',  (select count(*) from public.cliques where profile_id = p_id and created_at >= hoje),
    'por_link',      coalesce((select json_agg(x order by x.n desc) from (
                        select url, count(*) n from public.cliques
                         where profile_id = p_id and created_at >= desde group by url) x), '[]'::json),
    'por_origem',    coalesce((select json_agg(x order by x.visitas desc, x.cliques desc) from (
                        select coalesce(o.origem, '(direto)') origem, sum(o.v)::int visitas, sum(o.c)::int cliques from (
                          select utm_source origem, 1 v, 0 c from public.visitas where profile_id = p_id and created_at >= desde
                          union all
                          select utm_source, 0, 1 from public.cliques where profile_id = p_id and created_at >= desde) o
                        group by 1) x), '[]'::json),
    'por_dia',       coalesce((select json_agg(x order by x.dia) from (
                        select d::date dia,
                          (select count(*) from public.visitas v where v.profile_id = p_id
                             and (v.created_at at time zone 'America/Sao_Paulo')::date = d::date) visitas,
                          (select count(*) from public.cliques c where c.profile_id = p_id
                             and (c.created_at at time zone 'America/Sao_Paulo')::date = d::date) cliques
                        from generate_series((now() at time zone 'America/Sao_Paulo')::date - 13,
                                             (now() at time zone 'America/Sao_Paulo')::date, interval '1 day') d) x), '[]'::json)
  ) into r;
  return r;
end $$;

revoke all on function public.stats_perfil(uuid, int) from public, anon;
grant execute on function public.stats_perfil(uuid, int) to authenticated;

-- funções de trigger não devem ser chamáveis pela API
revoke all on function public.cliques_antes() from public, anon, authenticated;
revoke all on function public.visitas_antes() from public, anon, authenticated;
revoke all on function private.visitante_hash(uuid) from public, anon, authenticated;

-- master: lista com visitas também (muda o retorno, por isso drop)
drop function if exists public.master_lista();
create function public.master_lista()
returns table (id uuid, slug text, nome text, email text, instagram text, telefone text,
               ativo boolean, created_at timestamptz, cliques_30d bigint, visitas_30d bigint)
language sql stable security definer set search_path = '' as $$
  select p.id, p.slug, p.nome, u.email::text, p.instagram, p.telefone, p.ativo, p.created_at,
         (select count(*) from public.cliques c where c.profile_id = p.id and c.created_at > now() - interval '30 days'),
         (select count(*) from public.visitas v where v.profile_id = p.id and v.created_at > now() - interval '30 days')
  from public.profiles p
  join auth.users u on u.id = p.id
  where public.is_master()
  order by p.created_at desc;
$$;
revoke all on function public.master_lista() from public, anon;
grant execute on function public.master_lista() to authenticated;
