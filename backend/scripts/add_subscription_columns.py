"""Add proof_image and rejection_reason columns to subscription_requests

Run this script to add the missing columns to an existing database.
"""
import asyncio
from sqlalchemy import text
from app.core.database import async_session_factory


async def upgrade():
    async with async_session_factory() as session:
        # Check if columns exist before adding
        result = await session.execute(text("""
            SELECT column_name FROM information_schema.columns 
            WHERE table_name = 'subscription_requests' AND column_name = 'proof_image'
        """))
        if result.scalar_one_or_none() is None:
            await session.execute(text("""
                ALTER TABLE subscription_requests 
                ADD COLUMN proof_image VARCHAR(500)
            """))
            print("Added proof_image column")
        else:
            print("proof_image column already exists")

        result = await session.execute(text("""
            SELECT column_name FROM information_schema.columns 
            WHERE table_name = 'subscription_requests' AND column_name = 'rejection_reason'
        """))
        if result.scalar_one_or_none() is None:
            await session.execute(text("""
                ALTER TABLE subscription_requests 
                ADD COLUMN rejection_reason TEXT
            """))
            print("Added rejection_reason column")
        else:
            print("rejection_reason column already exists")

        result = await session.execute(text("""
            SELECT column_name FROM information_schema.columns 
            WHERE table_name = 'subscription_requests' AND column_name = 'period'
        """))
        if result.scalar_one_or_none() is None:
            await session.execute(text("""
                ALTER TABLE subscription_requests 
                ADD COLUMN period VARCHAR(20)
            """))
            print("Added period column")
        else:
            print("period column already exists")

        await session.commit()
        print("Migration completed successfully")


if __name__ == "__main__":
    asyncio.run(upgrade())
