import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import huddy/model
import huddy/state
import support

const now = 1_791_622_800_000

fn new_finding(
  agent: Int,
  item: Int,
  version: Int,
  kind: model.FindingKind,
) -> state.NewFinding {
  state.NewFinding(
    agent:,
    item: Some(item),
    item_version: Some(version),
    related_item: None,
    kind:,
    confidence: Some(0.9),
    message: "m",
    judgment: None,
  )
}

pub fn handles_are_unique_slugs_test() {
  let s = model.empty_state()
  let #(s, a) = state.create_user(s, "Alice.Smith@acme.dev", now)
  let #(s, b) = state.create_user(s, "alice.smith@other.dev", now)
  assert a.handle == "alice.smith"
  assert b.handle == "alice.smith-2"
  let assert Error(_) = state.set_handle(s, b.id, "alice.smith")
  let assert Error(_) = state.set_handle(s, b.id, "Not A Slug")
  let assert Ok(_) = state.set_handle(s, b.id, "asmith")
}

pub fn agents_are_shared_by_identity_test() {
  let #(s, a, _) = support.two_agents(now)
  let assert Ok(agent) = dict.get(s.agents, a)
  let #(s2, again) =
    state.ensure_agent(s, agent.owner, "codex", "huddy", now + 5)
  assert again.id == a
  assert dict.size(s2.agents) == dict.size(s.agents)
}

pub fn agents_can_have_several_goals_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, g1) = state.create_item(s, a, support.goal("First"), now)
  let #(s, g2) = state.create_item(s, a, support.goal("Second"), now + 1)
  let open_goals =
    state.open_items_of(s, a) |> list.filter(fn(i) { i.kind == model.Goal })
  assert list.map(open_goals, fn(i) { i.id }) == [g2.id, g1.id]
}

pub fn replace_goal_closes_only_that_goal_test() {
  let #(s, a, b) = support.two_agents(now)
  let #(s, g1) = state.create_item(s, a, support.goal("First"), now)
  let #(s, g2) = state.create_item(s, a, support.goal("Second"), now)
  let #(s, t) = state.create_item(s, a, support.task("A task"), now)
  let assert Ok(s) = state.replace_goal(s, a, g1.id, now + 1)
  let assert Some(old) = state.get_item(s, g1.id)
  assert old.state == model.Replaced
  assert option.is_some(old.closed_at)
  let assert Some(other) = state.get_item(s, g2.id)
  assert other.state == model.Active
  // not twice, not someone else's, not a task
  let assert Error(_) = state.replace_goal(s, a, g1.id, now + 2)
  let assert Error(message) = state.replace_goal(s, b, g2.id, now + 2)
  assert string.contains(message, "only replace their own")
  let assert Error(_) = state.replace_goal(s, a, t.id, now + 2)
}

pub fn agents_only_edit_their_own_items_test() {
  let #(s, a, b) = support.two_agents(now)
  let #(s, t) = state.create_item(s, a, support.task("Mine"), now)
  let edit = state.Edit(Some("Stolen"), None, None, None, None, None)
  let assert Error(message) = state.edit_item(s, b, t.id, edit, now)
  assert string.contains(message, "only change their own")
}

pub fn closing_states_follow_kind_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, t) = state.create_item(s, a, support.task("Work"), now)
  let close = fn(to) { state.Edit(None, None, None, None, Some(to), None) }
  let assert Error(_) = state.edit_item(s, a, t.id, close(model.Resolved), now)
  let assert Ok(#(s, out)) = state.edit_item(s, a, t.id, close(model.Done), now)
  assert out.item.state == model.Done
  let assert Error(message) =
    state.edit_item(s, a, t.id, close(model.Dropped), now)
  assert string.contains(message, "already closed")
}

pub fn edit_bumps_version_and_resolves_findings_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, t) = state.create_item(s, a, support.task("Work"), now)
  let assert #(s, Some(f)) =
    state.add_finding(s, new_finding(a, t.id, 1, model.Unclear), now, 0)
  let assert Ok(#(s, out)) =
    state.edit_item(
      s,
      a,
      t.id,
      state.Edit(Some("Clearer work"), None, None, None, None, None),
      now,
    )
  assert out.item.version == 2
  assert out.content_changed
  let assert Ok(after) = dict.get(s.findings, f.id)
  assert after.status == model.FindingResolved
}

pub fn findings_are_deduplicated_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, t) = state.create_item(s, a, support.task("Work"), now)
  let assert #(s, Some(_)) =
    state.add_finding(s, new_finding(a, t.id, 1, model.Unclear), now, 0)
  let #(_, second) =
    state.add_finding(s, new_finding(a, t.id, 1, model.Unclear), now, 0)
  assert second == None
}

pub fn dismissed_findings_stay_dismissed_for_that_version_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, t) = state.create_item(s, a, support.task("Work"), now)
  let assert #(s, Some(f)) =
    state.add_finding(s, new_finding(a, t.id, 1, model.Unclear), now, 0)
  let assert Ok(s) = state.dismiss_findings(s, a, [f.id], "it is clear", now)
  let #(_, again) =
    state.add_finding(s, new_finding(a, t.id, 1, model.Unclear), now, 0)
  assert again == None
  // a new version may be flagged again
  let #(_, v2) =
    state.add_finding(s, new_finding(a, t.id, 2, model.Unclear), now, 0)
  assert option.is_some(v2)
}

pub fn stale_dismissal_has_a_cooldown_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, t) = state.create_item(s, a, support.task("Work"), now)
  let cooldown = state.hours(24)
  let assert #(s, Some(f)) =
    state.add_finding(s, new_finding(a, t.id, 1, model.Stale), now, cooldown)
  let assert Ok(item) = dict.get(s.items, t.id)
  assert item.stale_p == Some(0.9)
  let assert Ok(s) = state.dismiss_findings(s, a, [f.id], "still working", now)
  let assert Ok(item) = dict.get(s.items, t.id)
  assert item.stale_p == None
  let #(_, soon) =
    state.add_finding(
      s,
      new_finding(a, t.id, 1, model.Stale),
      now + 1000,
      cooldown,
    )
  assert soon == None
  let #(_, later) =
    state.add_finding(
      s,
      new_finding(a, t.id, 1, model.Stale),
      now + cooldown + 1,
      cooldown,
    )
  assert option.is_some(later)
}

pub fn agents_cannot_dismiss_others_findings_test() {
  let #(s, a, b) = support.two_agents(now)
  let #(s, t) = state.create_item(s, a, support.task("Work"), now)
  let assert #(s, Some(f)) =
    state.add_finding(s, new_finding(a, t.id, 1, model.Unclear), now, 0)
  let assert Error(_) = state.dismiss_findings(s, b, [f.id], "nope", now)
}

pub fn findings_repeat_until_acked_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, t) = state.create_item(s, a, support.task("Work"), now)
  let assert #(s, Some(f)) =
    state.add_finding(s, new_finding(a, t.id, 1, model.Unclear), now, 0)
  let assert #(_, [first]) = state.unacked(s, a)
  let s = state.mark_sent(s, [], [first.id], now)
  // sent, but not acknowledged: still there
  let assert #(_, [again]) = state.unacked(s, a)
  assert again.id == f.id
  assert again.status == model.Delivered
  let assert Ok(s) = state.ack(s, a, [state.AckFinding(f.id)], now)
  assert state.unacked(s, a) == #([], [])
  // acked findings stay live for their display effects
  let assert Ok(acked) = dict.get(s.findings, f.id)
  assert model.finding_is_live(acked)
  // acking again is fine
  let assert Ok(_) = state.ack(s, a, [state.AckFinding(f.id)], now)
}

pub fn dismissing_acknowledges_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, t) = state.create_item(s, a, support.task("Work"), now)
  let assert #(s, Some(f)) =
    state.add_finding(s, new_finding(a, t.id, 1, model.Unclear), now, 0)
  let assert Ok(s) = state.dismiss_findings(s, a, [f.id], "fine", now)
  let assert Ok(d) = dict.get(s.findings, f.id)
  assert d.acked_at == Some(now)
  assert state.unacked(s, a) == #([], [])
}

pub fn agents_cannot_ack_others_entries_test() {
  let #(s, a, b) = support.two_agents(now)
  let #(s, t) = state.create_item(s, a, support.task("Work"), now)
  let assert #(s, Some(f)) =
    state.add_finding(s, new_finding(a, t.id, 1, model.Unclear), now, 0)
  let assert Ok(#(s, c)) =
    state.add_comment(s, t.id, model.HumanAuthor(2), "hi", None, limits, now)
  let assert Error(_) = state.ack(s, b, [state.AckFinding(f.id)], now)
  let assert Error(_) = state.ack(s, b, [state.AckComment(c.id)], now)
  let assert Error(_) = state.ack(s, a, [state.AckComment(999)], now)
  // all or nothing
  let assert Error(_) =
    state.ack(s, a, [state.AckComment(c.id), state.AckFinding(999)], now)
  let assert Ok(_) =
    state.ack(s, a, [state.AckComment(c.id), state.AckFinding(f.id)], now)
  assert state.parse_ack_ref("c7") == Ok(state.AckComment(7))
  assert state.parse_ack_ref(" f88 ") == Ok(state.AckFinding(88))
  let assert Error(_) = state.parse_ack_ref("88")
  let assert Error(_) = state.parse_ack_ref("i41")
}

const limits = state.CommentLimits(max_chars: 20, per_item: 3)

pub fn comments_are_checked_test() {
  let #(s, a, b) = support.two_agents(now)
  let #(s, t) = state.create_item(s, a, support.task("Work"), now)
  let #(s, d) =
    state.create_item(
      s,
      a,
      state.NewItem(model.Decision, "Which?", "", True, ["SES", "Postmark"], []),
      now,
    )
  let human = model.HumanAuthor(2)
  let assert Error(_) =
    state.add_comment(s, t.id, human, "  ", None, limits, now)
  let assert Error(_) =
    state.add_comment(s, t.id, human, string.repeat("x", 21), None, limits, now)
  // picks: decisions only, and only a current option
  let assert Error(_) =
    state.add_comment(s, t.id, human, "", Some("SES"), limits, now)
  let assert Error(_) =
    state.add_comment(s, d.id, human, "", Some("Mailgun"), limits, now)
  let assert Error(_) =
    state.add_comment(
      s,
      d.id,
      model.AgentAuthor(a),
      "",
      Some("SES"),
      limits,
      now,
    )
  // an agent replies only on its own items
  let assert Error(_) =
    state.add_comment(s, t.id, model.AgentAuthor(b), "mine?", None, limits, now)
  let assert Ok(#(s, c)) =
    state.add_comment(s, d.id, human, "", Some("Postmark"), limits, now)
  assert c.pick == Some("Postmark")
  // answering marks the decision seen
  let assert Some(seen) = state.get_item(s, d.id)
  assert seen.seen_by == Some(2)
  // at most `per_item`
  let assert Ok(#(s, _)) =
    state.add_comment(s, t.id, human, "1", None, limits, now)
  let assert Ok(#(s, _)) =
    state.add_comment(s, t.id, model.AgentAuthor(a), "2", None, limits, now)
  let assert Ok(#(s, _)) =
    state.add_comment(s, t.id, human, "3", None, limits, now)
  let assert Error(_) =
    state.add_comment(s, t.id, human, "4", None, limits, now)
  // closed items take no comments
  let assert Ok(#(s, _)) =
    state.edit_item(
      s,
      a,
      d.id,
      state.Edit(None, None, None, None, Some(model.Resolved), None),
      now,
    )
  let assert Error(_) =
    state.add_comment(s, d.id, human, "late", None, limits, now)
}

pub fn comments_repeat_until_acked_even_after_close_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, t) = state.create_item(s, a, support.task("Work"), now)
  let assert Ok(#(s, c)) =
    state.add_comment(s, t.id, model.HumanAuthor(2), "wait", None, limits, now)
  // the agent's own replies are not addressed to it
  let assert Ok(#(s, _)) =
    state.add_comment(s, t.id, model.AgentAuthor(a), "ok", None, limits, now)
  let assert #([pending], []) = state.unacked(s, a)
  assert pending.id == c.id
  let s = state.mark_sent(s, [c.id], [], now + 1)
  let assert Ok(#(s, _)) =
    state.edit_item(
      s,
      a,
      t.id,
      state.Edit(
        Some("Work, renamed"),
        None,
        None,
        None,
        Some(model.Done),
        None,
      ),
      now + 2,
    )
  let assert #([still], []) = state.unacked(s, a)
  assert still.sent_at == Some(now + 1)
  let assert Ok(s) = state.ack(s, a, [state.AckComment(c.id)], now + 3)
  assert state.unacked(s, a) == #([], [])
}

pub fn pruning_drops_comments_with_their_item_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, t) = state.create_item(s, a, support.task("Work"), now)
  let assert Ok(#(s, _)) =
    state.add_comment(s, t.id, model.HumanAuthor(2), "x", None, limits, now)
  let assert Ok(#(s, _)) =
    state.edit_item(
      s,
      a,
      t.id,
      state.Edit(None, None, None, None, Some(model.Done), None),
      now,
    )
  let later = now + state.days(31)
  let s = state.prune(s, state.RetentionPolicy(30, 90, 14, 90, 0), later)
  assert dict.size(s.comments) == 0
}

pub fn hiding_tells_the_agent_test() {
  let #(s, a, _) = support.two_agents(now)
  let #(s, t) = state.create_item(s, a, support.task("Work"), now)
  let assert Ok(s) = state.hide(s, t.id, 2, "superseded", now)
  let #(_, inbox) = state.unacked(s, a)
  let assert [f] = inbox
  assert f.kind == model.Hidden
  assert string.contains(f.message, "bob hid")
  assert string.contains(f.message, "superseded")
}

pub fn closing_an_item_resolves_overlaps_pointing_at_it_test() {
  let #(s, a, b) = support.two_agents(now)
  let #(s, mine) = state.create_item(s, a, support.task("Deflake"), now)
  let #(s, theirs) = state.create_item(s, b, support.task("Deflake too"), now)
  let overlap =
    state.NewFinding(
      ..new_finding(a, mine.id, 1, model.Overlap),
      related_item: Some(theirs.id),
    )
  let assert #(s, Some(_)) = state.add_finding(s, overlap, now, 0)
  let assert Ok(item) = dict.get(s.items, mine.id)
  assert item.overlaps == Some(theirs.id)
  let assert Ok(#(s, _)) =
    state.edit_item(
      s,
      b,
      theirs.id,
      state.Edit(None, None, None, None, Some(model.Done), None),
      now,
    )
  let assert Ok(item) = dict.get(s.items, mine.id)
  assert item.overlaps == None
}

pub fn prune_keeps_references_valid_test() {
  let #(s, a, b) = support.two_agents(now)
  let #(s, mine) = state.create_item(s, a, support.task("Old"), now)
  let #(s, theirs) = state.create_item(s, b, support.task("Current"), now)
  let overlap =
    state.NewFinding(
      ..new_finding(b, theirs.id, 1, model.Overlap),
      related_item: Some(mine.id),
    )
  let #(s, _) = state.add_finding(s, overlap, now, 0)
  let assert Ok(#(s, _)) =
    state.edit_item(
      s,
      a,
      mine.id,
      state.Edit(None, None, None, None, Some(model.Done), None),
      now,
    )
  let policy = state.RetentionPolicy(30, 90, 14, 90, 0)
  let s = state.prune(s, policy, now + state.days(31))
  assert state.get_item(s, mine.id) == None
  assert option.is_some(state.get_item(s, theirs.id))
  assert dict.values(s.findings)
    |> list.all(fn(f) { f.related_item != Some(mine.id) })
}

pub fn prune_closes_then_drops_inactive_agents_items_test() {
  let #(s, a, b) = support.two_agents(now)
  let #(s, goal) = state.create_item(s, a, support.goal("Ship it"), now)
  let #(s, task) = state.create_item(s, a, support.task("Deflake"), now)
  let #(s, ask) =
    state.create_item(s, a, support.decision("Which queue?", True), now)
  let #(s, theirs) = state.create_item(s, b, support.task("Deflake too"), now)
  let overlap =
    state.NewFinding(
      ..new_finding(b, theirs.id, 1, model.Overlap),
      related_item: Some(task.id),
    )
  let #(s, _) = state.add_finding(s, overlap, now, 0)
  let s = state.touch_agent(s, b, now + state.days(2))
  let policy = state.RetentionPolicy(30, 90, 14, 90, 3)

  // 0 keeps them open
  let kept =
    state.prune(
      s,
      state.RetentionPolicy(..policy, inactive_agent_days: 0),
      now + state.days(4),
    )
  assert list.length(state.open_items(kept)) == 4

  let later = now + state.days(4)
  let s = state.prune(s, policy, later)
  let state_of = fn(id) {
    let assert Some(i) = state.get_item(s, id)
    #(i.state, i.closed_at)
  }
  assert state_of(goal.id) == #(model.Abandoned, Some(later))
  assert state_of(task.id) == #(model.Dropped, Some(later))
  assert state_of(ask.id) == #(model.Withdrawn, Some(later))
  let assert Some(i) = state.get_item(s, theirs.id)
  assert model.is_open(i)
  assert i.overlaps == None

  // then retention deletes them like any closed item
  let s = state.prune(s, policy, later + state.days(31))
  assert state.get_item(s, goal.id) == None
  assert state.get_item(s, task.id) == None
  assert state.get_item(s, ask.id) == None
}

pub fn refresh_family_revocation_test() {
  let #(s, _, _) = support.two_agents(now)
  let #(s, g) = state.ensure_grant(s, "dcr_x", 1, "huddy:read huddy:write", now)
  let token = fn(sha, kind) {
    model.OAuthToken(sha, g.id, kind, "fam", "https://h/mcp", now + 1000, None)
  }
  let s =
    s
    |> state.put_token(token("a", model.AccessToken))
    |> state.put_token(token("r", model.RefreshToken))
  assert option.is_some(state.valid_token(s, "a", model.AccessToken, now))
  let s = state.revoke_family(s, "fam")
  assert state.valid_token(s, "a", model.AccessToken, now) == None
  // revoking the grant also drops its tokens
  let s = state.put_token(s, token("b", model.AccessToken))
  let s = state.revoke_grant(s, g.id, 1, now)
  assert state.valid_token(s, "b", model.AccessToken, now) == None
}
