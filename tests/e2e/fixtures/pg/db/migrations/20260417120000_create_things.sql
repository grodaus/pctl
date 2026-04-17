-- migrate:up
create table things (
  id    serial primary key,
  name  text not null,
  added timestamptz not null default now()
);

-- migrate:down
drop table things;
