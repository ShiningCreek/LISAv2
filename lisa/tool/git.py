import pathlib

from lisa.core.tool import Tool


class Git(Tool):
    @property
    def command(self) -> str:
        return "git"

    @property
    def canInstall(self) -> bool:
        # TODO support installation later
        return False

    def clone(self, url: str, cwd: pathlib.Path) -> None:
        self.run(f"clone {url}", cwd=cwd)