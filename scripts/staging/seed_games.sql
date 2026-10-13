-- STAGING ONLY. Never run on production (production gets its list from the platform's own "Sync Game List" push).
--
-- Loads the games the Tulasi dashboard lists for merchant 1503251 (ids and paths read from its Merchant Game Config page)
-- into staging's merchant_games, the same way the platform's push would (public.game_sync_list). No pictures yet: the app shows a
-- placeholder until the platform's own "Sync Game List" arrives, which also re-hosts the pictures and overwrites these rows.
--
--   cd sabalive && supabase db query --linked --workdir ~/.sabalive-staging-workdir -f scripts/staging/seed_games.sql
--
-- The game address the app builds from a row:
--   https://gamesp.tulasigame.com/<gameIdentification>/?merchant=1503251&gameId=<id>&lang=en&isLandscape=false&roomId=111&token=<token>
-- e.g. Roulette: https://gamesp.tulasigame.com/roulette/?merchant=1503251&gameId=2875&...
-- (The dashboard lists a tenth game, id 2874, whose name and path were not captured: the platform's sync will add it.)
select public.game_sync_list('[
 {"id":2883,"name":"Teen Patti Gold","gameIdentification":"kingdoms","status":1,"merchantId":1503251},
 {"id":2882,"name":"Teen Patti","gameIdentification":"kingdoms2","status":1,"merchantId":1503251},
 {"id":2881,"name":"Lucky77","gameIdentification":"lucky77","status":1,"merchantId":1503251},
 {"id":2880,"name":"Lucky99","gameIdentification":"lucky99","status":1,"merchantId":1503251},
 {"id":2879,"name":"Fruit Loops","gameIdentification":"fruitLoops","status":1,"merchantId":1503251},
 {"id":2878,"name":"Greedy","gameIdentification":"greedy","status":1,"merchantId":1503251},
 {"id":2877,"name":"Fruit Machine","gameIdentification":"fruitMachine","status":1,"merchantId":1503251},
 {"id":2876,"name":"Dragon Tiger Battle","gameIdentification":"dragonTigerBattle","status":1,"merchantId":1503251},
 {"id":2875,"name":"Roulette","gameIdentification":"roulette","status":1,"merchantId":1503251}
]'::jsonb) as games_written;

select id, name, identification, status, sort_order from public.merchant_games order by sort_order;
