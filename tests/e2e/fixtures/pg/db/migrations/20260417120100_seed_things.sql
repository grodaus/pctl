-- migrate:up
insert into things (name) values
  ('hello from pctl'),
  ('second row');

-- migrate:down
delete from things where name in ('hello from pctl', 'second row');
