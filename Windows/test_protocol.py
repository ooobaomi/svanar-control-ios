"""Offline regression checks: no device connection or writes."""
import unittest
from headphone_ble import encode, decode, decode_eq, eq_payload, Session


class ProtocolTests(unittest.TestCase):
    def test_known_query_crc(self):
        self.assertEqual(encode(6).hex(), 'fe06000000c66b')

    def test_mode_response(self):
        self.assertEqual(decode(bytes.fromhex('fe0600000201003c6e')), (6, b'\x01\x00'))

    def test_bad_frames(self):
        for frame in (b'', b'\xfe\x06', bytes.fromhex('fe0600000201000000'),
                      bytes.fromhex('fe0600000301003c6e')):
            with self.subTest(frame=frame), self.assertRaises(ValueError):
                decode(frame)

    def test_signed_eq(self):
        gains = [-10,-5,-1,0,1,2,3,5,8,10]
        self.assertEqual(decode_eq(eq_payload(gains)), gains)

    def test_invalid_eq(self):
        for gains in ([0]*9, [11]*10, [-11]*10, [0.5]*10):
            with self.subTest(gains=gains), self.assertRaises(ValueError):
                eq_payload(gains)

    def test_split_and_combined_packets(self):
        session = Session(None)
        frame = encode(6, bytes([2,0]))
        session.notify(None, frame[:4])
        self.assertTrue(session.responses.empty())
        session.notify(None, frame[4:] + frame)
        self.assertEqual(session.responses.get_nowait(), (6, bytes([2,0])))
        self.assertEqual(session.responses.get_nowait(), (6, bytes([2,0])))


if __name__ == '__main__':
    unittest.main()
