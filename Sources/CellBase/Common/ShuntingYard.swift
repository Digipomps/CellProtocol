// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  ShuntingYard.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 05/03/2025.
//

import Foundation

// Støttede operatorer og deres presedens
let operators: [Character: (precedence: Int, associativity: String)] = [
    "+": (1, "L"),
    "-": (1, "L"),
    "*": (2, "L"),
    "/": (2, "L"),
    "^": (3, "R")
]

// Konverter infix til postfix (RPN)
func shuntingYard(_ expression: String) -> [String] {
    var output: [String] = []
    var operatorStack: [Character] = []
    var numberBuffer: String = ""

    for char in expression.replacingOccurrences(of: " ", with: "") {
        if char.isNumber || char == "." {
            numberBuffer.append(char) // Bygger opp tall
        } else {
            if !numberBuffer.isEmpty {
                output.append(numberBuffer)
                numberBuffer = ""
            }
            if let op = operators[char] {
                while let lastOp = operatorStack.last,
                      let lastOpInfo = operators[lastOp],
                      (op.associativity == "L" && op.precedence <= lastOpInfo.precedence) ||
                      (op.associativity == "R" && op.precedence < lastOpInfo.precedence) {
                    output.append(String(operatorStack.removeLast()))
                }
                operatorStack.append(char)
            } else if char == "(" {
                operatorStack.append(char)
            } else if char == ")" {
                while let lastOp = operatorStack.last, lastOp != "(" {
                    output.append(String(operatorStack.removeLast()))
                }
                _ = operatorStack.popLast() // Fjern '('
            }
        }
    }
    
    if !numberBuffer.isEmpty {
        output.append(numberBuffer)
    }
    
    while let lastOp = operatorStack.popLast() {
        output.append(String(lastOp))
    }

    return output
}

// Evaluerer postfix (RPN) uttrykket
func evaluateRPN(_ tokens: [String]) -> Double? {
    var stack: [Double] = []
    
    for token in tokens {
        if let number = Double(token) {
            stack.append(number)
        } else if let op = token.first, operators.keys.contains(op) {
            guard stack.count >= 2 else { return nil }
            let right = stack.popLast()!
            let left = stack.popLast()!
            
            switch op {
                case "+": stack.append(left + right)
                case "-": stack.append(left - right)
                case "*": stack.append(left * right)
                case "/": stack.append(left / right)
                case "^": stack.append(pow(left, right))
                default: return nil
            }
        }
    }
    
    return stack.last
}

// Hovedfunksjon for å evaluere infix-uttrykk
func evaluateExpression(_ expression: String) -> Double? {
    let rpn = shuntingYard(expression)
    return evaluateRPN(rpn)
}

// **Testeksempler**
func testit() {
    let testExpression = "3 + 4 * 2 / ( 1 - 5 ) ^ 2"
    if let result = evaluateExpression(testExpression) {
        print("\(testExpression) = \(result)")  // Forventet output: 3.5
    } else {
        print("Feil i evaluering")
    }
}
