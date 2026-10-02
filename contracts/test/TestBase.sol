// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);

    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function expectRevert() external;
}

abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertEq(uint256 actual, uint256 expected) internal pure {
        require(actual == expected, "uint assertion failed");
    }

    function assertTrue(bool value) internal pure {
        require(value, "true assertion failed");
    }

    //Given value must be false or else assertion failed
    function assertFalse(bool value) internal pure {
        require(!value, "false assertion failed");
    }

    function assertEq32(bytes32 actual, bytes32 expected) internal pure {
        require(actual == expected, "bytes32 assertion failed");
    }

    function assertEqAddr(address actual, address expected) internal pure {
        require(actual == expected, "address assertion failed");
    }

    function _countLogs(
        Vm.Log[] memory logs,
        bytes32 topic0
    ) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic0) n++;
        }
    }

    function _firstLog(
        Vm.Log[] memory logs,
        bytes32 topic0
    ) internal pure returns (Vm.Log memory) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic0)
                return logs[i];
        }
        revert("log not found");
    }
}

