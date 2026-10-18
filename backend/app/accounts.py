"""Manage accounts on a deployed server.

    python -m app.accounts list
    python -m app.accounts link-owner <user-id>

`link-owner` moves a Google sign-in onto the owner account (the single local user from
before sign-in existed), so the owner's recipes and photos appear when they sign in with
Google. Sign in once with Google first: that creates an empty account, whose ID `list`
shows. It must still be empty; it's deleted, its devices are signed out, and its Google
identity is given to the owner. The owner keeps its ID, so photo keys stay valid.
"""

import argparse
import uuid

from sqlalchemy import create_engine, func, select
from sqlalchemy.orm import Session

from app.config import DEV_USER_ID, get_settings
from app.models import ApiToken, ImportDraft, Recipe, User


class LinkError(Exception):
    pass


def link_owner(session: Session, google_user_id: uuid.UUID) -> str:
    """Give `google_user_id`'s Google identity to the owner. Returns the identity."""
    if google_user_id == DEV_USER_ID:
        raise LinkError("That's the owner account itself; pass the new Google account's ID.")
    owner = session.get(User, DEV_USER_ID, with_for_update=True)
    if owner is None:
        raise LinkError("There's no owner account on this server.")
    if owner.auth_subject is not None:
        raise LinkError(f"The owner is already linked to {owner.auth_subject}.")
    other = session.get(User, google_user_id, with_for_update=True)
    if other is None or other.auth_subject is None or not other.auth_subject.startswith("google:"):
        raise LinkError("No Google account has that ID.")
    for model in (Recipe, ImportDraft):
        if session.scalar(select(func.count()).select_from(model).where(model.user_id == other.id)):
            raise LinkError("That Google account already has recipes or drafts; refusing to delete them.")
    subject = other.auth_subject
    session.delete(other)  # its device tokens go with it (ON DELETE CASCADE)
    session.flush()
    owner.auth_subject = subject
    session.flush()
    return subject


def main() -> None:
    ap = argparse.ArgumentParser(prog="python -m app.accounts")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    link = sub.add_parser("link-owner")
    link.add_argument("google_user_id", type=uuid.UUID)
    args = ap.parse_args()

    engine = create_engine(get_settings().database_url, connect_args={"options": "-c timezone=UTC"})
    with Session(engine) as s:
        if args.cmd == "list":
            recipes = dict(s.execute(select(Recipe.user_id, func.count()).group_by(Recipe.user_id)).all())
            devices = dict(s.execute(
                select(ApiToken.user_id, func.count()).where(ApiToken.revoked_at.is_(None)).group_by(ApiToken.user_id)
            ).all())
            for u in s.scalars(select(User).order_by(User.created_at)):
                who = "owner" if u.id == DEV_USER_ID else "     "
                print(f"{u.id}  {who}  {u.auth_subject or '(no sign-in)':32}  "
                      f"{recipes.get(u.id, 0):4} recipes  {devices.get(u.id, 0)} devices  created {u.created_at:%Y-%m-%d}")
        else:
            try:
                subject = link_owner(s, args.google_user_id)
            except LinkError as e:
                raise SystemExit(str(e))
            s.commit()
            print(f"Linked {subject} to the owner. Sign in with Google again on each device.")


if __name__ == "__main__":
    main()
