class InteractionError(Exception):
    pass


class ValidationError(InteractionError):
    def __init__(self, path: str, message: str) -> None:
        self.path = path
        super().__init__(f"{path}: {message}")


class TransportError(InteractionError):
    pass


class SequenceError(InteractionError):
    pass
