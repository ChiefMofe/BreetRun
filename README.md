# Breet Run

A pixel-art runner starring the Breet bunny. Run through the Bad Rate Zone across 10 levels, dodge P2P bombs, Low Rates chests, Hidden Fees and rug pulls, grab coins, and cash out at the Breet building.

Players pick a unique username before their first run, and every finished level is saved to a leaderboard (one per level, plus an overall board).

## What's in here

| File | What it is |
| --- | --- |
| `index.html` | The whole game in one file. No build step, no dependencies. |
| `supabase/setup.sql` | Database setup for usernames and the leaderboard. |

## Play it locally

Open `index.html` in a browser. Tap, click or press Space to jump; hold for a higher jump.

Until Supabase is connected, the game runs in **demo mode**: usernames and scores are kept in that browser only.

## Connect the leaderboard (Supabase)

1. Create a project at [supabase.com](https://supabase.com).
2. Open **SQL Editor**, paste in all of `supabase/setup.sql`, and run it. It's safe to run again later.
3. From the project's API settings, copy the **Project URL** and the **publishable key** (an older project's `anon` key also works).
4. In `index.html`, near the top of the `<script>`, fill in:
   ```js
   const SUPABASE_URL = "https://your-project.supabase.co";
   const SUPABASE_KEY = "sb_publishable_...";
   ```
5. Commit, push and deploy.

The publishable (or `anon`) key is designed to be public, so it's fine in this repo and in the page. **Never** put the secret or `service_role` key in this repo.

## Deploy

**GitHub Pages:** in the repo, go to **Settings → Pages**, choose **Deploy from a branch**, pick `main` and `/ (root)`, and save. The game will be live at:

```
https://chiefmofe.github.io/BreetRun/
```

Pages is free for public repos; private repos need a paid GitHub plan. Any other static host (Netlify, Vercel, a page on breet.io) works too: just serve `index.html`.

## How the leaderboard stays fair

- **Unique names.** Usernames are 3 to 16 letters, numbers or `_`, unique ignoring case (`Hopper` and `hopper` are the same name). Names containing "breet", and names like admin, support, official, moderator, mod and staff, are reserved.
- **Nobody can post as you.** Claiming a name creates a secret token that stays in the player's browser. The database only stores a hash of it, and scores are only accepted with the matching token.
- **Locked tables.** Row level security is on with no policies, so the browser can't read or write tables directly. It can only call five functions: `username_available`, `claim_username`, `submit_score`, `leaderboard` and `player_standing`.
- **Sanity checks.** A score can't be more than the level's coins x $200 (see the `level_caps` table), and two saves for the same level within 15 seconds are rejected.

Known limits:

- If a player clears their browser data or switches devices, they lose access to their username. Adding Supabase Auth (for example a magic link) would let them recover it.
- A determined player could fake a run from their browser's dev tools. If you're giving out prizes, check the top scores before announcing winners.

Useful admin queries (run in the SQL Editor):

```sql
-- Top 20 overall
select * from public.leaderboard(null, 20);

-- Remove a player and all their scores
delete from public.players where lower(username) = lower('their_name');
```

## Changing the game

- **Levels** live in the `LEVELS` list in `index.html`. Each level's layout is generated from a fixed seed, so it's identical every time it's played.
- **If you change a level**, update its coin count in the `level_caps` insert in `supabase/setup.sql` and run that file again. Otherwise valid scores may be rejected. The level-complete screen shows each level's total as `Coins (x/total)`. Current counts:

  | Level | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
  | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
  | Coins | 78 | 76 | 105 | 118 | 113 | 110 | 102 | 137 | 122 | 141 |

- **Before launch**, remove the "Unlock all levels (preview)" link (the `unlockAllBtn` button and its click handler in `index.html`). It's there so the team can test any level without playing through.
# BreetRun
