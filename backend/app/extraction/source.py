"""What a provider is given, and what its output is checked against.

`render_post` is the model's input: each part of the post in its own delimited block, so
the prompt can say where the recipe came from. `fidelity_text` is the plain text the
validator checks every ingredient and step against: all of it is from the post.
"""

from app.ingest import RawPost


def as_post(post: RawPost | str) -> RawPost:
    """Plain text (tests, the eval's old cases) is a post pasted without a link."""
    if isinstance(post, RawPost):
        return post
    return RawPost(
        platform=None, post_id=None, url=None, author_handle=None, caption=post,
        transcript=None, top_comments=[], media_urls=[], posted_at=None,
    )


def supplied_fields(post: RawPost) -> set[str]:
    fields = {"caption"}
    if post.transcript:
        fields.add("transcript")
    if post.top_comments:
        fields.add("comments")
    return fields


def render_post(post: RawPost) -> str:
    parts = [f"<caption>\n{post.caption}\n</caption>"]
    if post.transcript:
        parts.append(f"<transcript>\n{post.transcript}\n</transcript>")
    if post.top_comments:
        comments = "\n".join(f"<comment>\n{c}\n</comment>" for c in post.top_comments)
        parts.append(f"<comments>\n{comments}\n</comments>")
    return "\n".join(parts)


def fidelity_text(post: RawPost) -> str:
    return "\n".join([post.caption, post.transcript or "", *post.top_comments])
