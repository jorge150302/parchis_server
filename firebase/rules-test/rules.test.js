// Firestore security rules tests. Run inside the emulator:
//   firebase emulators:exec --only firestore --project demo-parchis \
//     "npm --prefix firebase/rules-test test"
import { readFileSync } from 'node:fs';
import { after, before, beforeEach, test } from 'node:test';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  deleteDoc, doc, getDoc, increment, serverTimestamp, setDoc, updateDoc,
} from 'firebase/firestore';

let env;

const newProfile = {
  display_name: 'Ana', photo_url: null, xp: 0, level: 1, wins: 0,
  matches_played: 0, tokens_capture: 0, avatar_type: 'google',
  avatar_icon_id: null, updated_at: serverTimestamp(),
};

before(async () => {
  const [host, port] = process.env.FIRESTORE_EMULATOR_HOST.split(':');
  env = await initializeTestEnvironment({
    projectId: 'demo-parchis',
    firestore: {
      host, port: Number(port),
      rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8'),
    },
  });
});

after(() => env.cleanup());

beforeEach(async () => {
  await env.clearFirestore();
  // Seed an existing profile with server-written values, bypassing rules.
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'users/alice'), {
      ...newProfile, xp: 500, level: 5, wins: 3, matches_played: 9,
      active_match_id: '12345',
    });
    await setDoc(doc(db, 'users/alice/match_results/m1'), { xp: 60 });
  });
});

const as = (uid) => env.authenticatedContext(uid).firestore();

test('owner can create a fresh profile', async () => {
  await assertSucceeds(setDoc(doc(as('bob'), 'users/bob'), newProfile));
});

test('a new profile cannot start with XP or stats', async () => {
  const db = as('bob');
  await assertFails(setDoc(doc(db, 'users/bob'), { ...newProfile, xp: 5000 }));
  await assertFails(setDoc(doc(db, 'users/bob'), { ...newProfile, wins: 10 }));
  await assertFails(setDoc(doc(db, 'users/bob'), { ...newProfile, level: 50 }));
  await assertFails(setDoc(doc(db, 'users/bob'),
    { ...newProfile, active_match_id: '999' }));
});

test('owner can change cosmetic fields', async () => {
  await assertSucceeds(updateDoc(doc(as('alice'), 'users/alice'), {
    avatar_type: 'icon', avatar_icon_id: 'cat', updated_at: serverTimestamp(),
  }));
  await assertSucceeds(updateDoc(doc(as('alice'), 'users/alice'),
    { photo_url: 'https://x/y.png' }));
});

test('owner cannot grant themselves XP, level or stats', async () => {
  const ref = doc(as('alice'), 'users/alice');
  await assertFails(updateDoc(ref, { xp: 99999 }));
  await assertFails(updateDoc(ref, { level: 100 }));
  await assertFails(updateDoc(ref, { wins: increment(1) }));
  await assertFails(updateDoc(ref, { matches_played: increment(1) }));
  await assertFails(updateDoc(ref, { tokens_capture: increment(5) }));
  await assertFails(updateDoc(ref, { avatar_type: 'icon', xp: 600 }));
});

test('owner can clear active_match_id but not set it', async () => {
  const ref = doc(as('alice'), 'users/alice');
  await assertFails(updateDoc(ref, { active_match_id: '77777' }));
  await assertSucceeds(updateDoc(ref, { active_match_id: null }));
});

test('nobody can read or write another account', async () => {
  const db = as('mallory');
  await assertFails(getDoc(doc(db, 'users/alice')));
  await assertFails(updateDoc(doc(db, 'users/alice'), { avatar_type: 'x' }));
  await assertFails(deleteDoc(doc(db, 'users/alice')));
  await assertFails(getDoc(doc(db, 'users/alice/match_results/m1')));
});

test('unauthenticated clients get nothing', async () => {
  const db = env.unauthenticatedContext().firestore();
  await assertFails(getDoc(doc(db, 'users/alice')));
  await assertFails(setDoc(doc(db, 'users/anon'), newProfile));
});

test('server history is readable and deletable by its owner, never writable', async () => {
  const db = as('alice');
  await assertSucceeds(getDoc(doc(db, 'users/alice/match_results/m1')));
  await assertFails(setDoc(doc(db, 'users/alice/match_results/fake'), { xp: 100 }));
  await assertFails(setDoc(doc(db, 'users/alice/xp_receipts/r1'), {}));
  await assertSucceeds(deleteDoc(doc(db, 'users/alice/match_results/m1')));
});

test('the app cannot grant itself items', async () => {
  const db = as('alice');
  await assertFails(setDoc(doc(db, 'users/alice/inventory/dice_gold'),
    { source: 'purchase:fake' }));
  await assertSucceeds(getDoc(doc(db, 'users/alice/inventory/dice_gold')));
});

test('owner can delete their profile', async () => {
  await assertSucceeds(deleteDoc(doc(as('alice'), 'users/alice')));
});

test('other collections are closed', async () => {
  await assertFails(setDoc(doc(as('alice'), 'leaderboard/x'), { a: 1 }));
  await assertFails(getDoc(doc(as('alice'), 'config/app')));
});
