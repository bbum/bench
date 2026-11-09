"""Tags each decoded UART byte, so tests can check settings and output end to end."""

from saleae.analyzers import AnalyzerFrame, ChoicesSetting, HighLevelAnalyzer, NumberSetting, StringSetting


class ByteTagger(HighLevelAnalyzer):
    prefix = StringSetting()
    scale = NumberSetting(min_value=0, max_value=100)
    case = ChoicesSetting(choices=("keep", "lower"))

    result_types = {"tagged": {"format": "{{data.text}}"}}

    def decode(self, frame):
        if frame.type != "data":
            return None
        value = frame.data["data"][0]
        character = chr(value).lower() if self.case == "lower" else chr(value)
        return AnalyzerFrame(
            "tagged", frame.start_time, frame.end_time, {"text": self.prefix + character, "scaled": value * self.scale}
        )
