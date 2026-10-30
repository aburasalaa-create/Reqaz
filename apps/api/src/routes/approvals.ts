import { many, type Tx } from '../db.js';

/** Approval trail of a document plus the levels it needs at its amount and which are already signed. */
export async function approvalInfo(t: Tx, docType: string, id: string, amount: string | number | null) {
  const history = await many(t, `
    select h.id, h.level, h.action, h.amount, h.comment, h.created_at, u.full_name as actor_name
    from public.approval_history h left join public.app_users u on u.id = h.actor_id
    where h.doc_type = $1 and h.doc_id = $2 order by h.id`, [docType, id]);
  const levels = await many(t, `
    select r.level, r.min_amount, ro.name_en as role_name,
           exists (select 1 from public.current_approvals($1, $2) a where a.level = r.level) as signed
    from public.required_approval_levels($1, $3) r left join public.roles ro on ro.id = r.role_id order by r.level`,
    [docType, id, amount ?? 0]);
  return { history, levels };
}
