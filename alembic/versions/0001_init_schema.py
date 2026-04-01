"""init schema

Revision ID: 0001_init_schema
Revises:
Create Date: 2026-04-01
"""

from alembic import op
import sqlalchemy as sa

revision = '0001_init_schema'
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table('users',
        sa.Column('id', sa.String(length=64), primary_key=True),
        sa.Column('nickname', sa.String(length=64), nullable=False),
    )


def downgrade() -> None:
    op.drop_table('users')
