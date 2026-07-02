"""Quick readiness probe: connect to a Wyoming server and request Info.
Exits 0 if the server responds with an Info describe, 1 otherwise."""
import asyncio
import sys


async def main(uri: str) -> int:
    try:
        from wyoming.client import AsyncTcpClient
        from wyoming.info import Describe, Info

        async with AsyncTcpClient.from_uri(uri) as client:
            await client.write_event(Describe().event())
            # wait up to ~5s for an Info reply
            for _ in range(50):
                event = await asyncio.wait_for(client.read_event(), timeout=5)
                if event is None:
                    return 1
                if Info.is_type(event.type):
                    print("READY")
                    return 0
        return 1
    except Exception as e:
        print(f"not-ready: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv[1])))
